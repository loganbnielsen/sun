type deployment_mode = Local | Customer_cloud | Sun_hosted

type env_config = {
  name           : string;
  mode           : deployment_mode;
  registry       : string;
  image_tag      : string;
  region         : string option;
  base_domain    : string option;
  secret_backend : Sun_cli_manifest.secret_backend;
}

type primitive = Svc | Worker | Fn

type effective_rollout_strategy =
  | Effective_canary
  | Effective_blue_green
  | Effective_recreate
  | Effective_rolling_update

type k8s_name = Sun_cli_kubernetes_name.k8s_name
type namespace = Sun_cli_kubernetes_name.namespace

type service_spec = {
  domain                : string;
  source_name           : string;
  k8s_name              : k8s_name;
  namespace             : namespace;
  primitive             : primitive;
  source_dir            : string;
  image                 : string;
  config                : (string * string) list;
  secrets               : (string * string) list;
  schedule              : string option;
  replicas              : int;
  cpu                   : string;
  memory                : string;
  rollout_strategy      : Sun_cli_toml.rollout_strategy option;
  ingress_host          : string option;
  ingress_path          : string option;
  extra_labels          : (string * string) list;
  progressive_delivery  : Sun_cli_toml.progressive_delivery option;
}

type t = {
  workspace        : string;
  environment      : env_config;
  services         : service_spec list;
  topics           : string list;
  migrations       : string list;
  schema_subjects  : string list;
  consumer_groups  : string list;
}

type plan_error =
  | Toml_error of Sun_cli_toml.parse_error
  | Invalid_kubernetes_name of { field : string; value : string; message : string }

let ( let* ) = Result.bind

let mode_to_string = function
  | Local          -> "local"
  | Customer_cloud -> "customer_cloud"
  | Sun_hosted     -> "sun_hosted"

let prim_to_string = function
  | Svc    -> "svc"
  | Worker -> "worker"
  | Fn     -> "fn"

let secret_backend_to_json backend =
  `String (Sun_cli_manifest.secret_backend_to_string backend)

let effective_rollout_strategy s =
  match s.progressive_delivery with
  | Some (Sun_cli_toml.Canary _) -> Effective_canary
  | Some Sun_cli_toml.Blue_green -> Effective_blue_green
  | None ->
    (match s.rollout_strategy with
     | Some Sun_cli_toml.Recreate -> Effective_recreate
     | Some Sun_cli_toml.RollingUpdate
     | None -> Effective_rolling_update)

let effective_rollout_strategy_to_string = function
  | Effective_canary         -> "canary"
  | Effective_blue_green     -> "blue_green"
  | Effective_recreate       -> "recreate"
  | Effective_rolling_update -> "rolling_update"

let k8s_name_to_string = Sun_cli_kubernetes_name.k8s_name_to_string
let namespace_to_string = Sun_cli_kubernetes_name.namespace_to_string

let canary_step_to_json = function
  | Sun_cli_toml.Weight n ->
    `Assoc [ "setWeight", `Int n ]
  | Sun_cli_toml.Pause None ->
    `Assoc [ "pause", `Assoc [] ]
  | Sun_cli_toml.Pause (Some seconds) ->
    `Assoc [ "pause", `Assoc [ "durationSeconds", `Int seconds ] ]

let progressive_delivery_to_json = function
  | None ->
    `Null
  | Some (Sun_cli_toml.Canary { steps }) ->
    `Assoc [
      "strategy", `String "canary";
      "steps",    `List (List.map canary_step_to_json steps);
    ]
  | Some Sun_cli_toml.Blue_green ->
    `Assoc [
      "strategy", `String "blue_green";
    ]

let to_json t =
  let opt_string = function
    | None   -> `Null
    | Some s -> `String s
  in
  let ingress_json s =
    match s.ingress_host with
    | None      -> `Null
    | Some host ->
      let path = Option.value s.ingress_path ~default:"/" in
      `Assoc [ "host", `String host; "path", `String path ]
  in
  let service_to_json (s : service_spec) =
    let rollout_strategy =
      s
      |> effective_rollout_strategy
      |> effective_rollout_strategy_to_string
    in
    `Assoc [
      "k8s_name",    `String (k8s_name_to_string s.k8s_name);
      "domain",      `String s.domain;
      "source_name", `String s.source_name;
      "namespace",   `String (namespace_to_string s.namespace);
      "primitive",   `String (prim_to_string s.primitive);
      "image",       `String s.image;
      "config",      `Assoc (List.map (fun (k, v) -> (k, `String v)) s.config);
      "secret_keys", `List  (List.map (fun (k, _) -> `String k) s.secrets);
      "schedule",    opt_string s.schedule;
      "replicas",    `Int    s.replicas;
      "cpu",         `String s.cpu;
      "memory",      `String s.memory;
      "rollout_strategy",     `String rollout_strategy;
      "ingress",              ingress_json s;
      "progressive_delivery", progressive_delivery_to_json s.progressive_delivery;
    ]
  in
  let env = t.environment in
  `Assoc [
    "_note",       `String "experimental — schema not frozen";
    "workspace",   `String t.workspace;
    "environment", `Assoc [
      "name",           `String env.name;
      "mode",           `String (mode_to_string env.mode);
      "registry",       `String env.registry;
      "image_tag",      `String env.image_tag;
      "region",         opt_string env.region;
      "base_domain",    opt_string env.base_domain;
      "secret_backend", secret_backend_to_json env.secret_backend;
    ];
    "services",         `List (List.map service_to_json t.services);
    "topics",           `List (List.map (fun s -> `String s) t.topics);
    "migrations",       `List (List.map (fun s -> `String s) t.migrations);
    "schema_subjects",  `List (List.map (fun s -> `String s) t.schema_subjects);
    "consumer_groups",  `List (List.map (fun s -> `String s) t.consumer_groups);
  ]

let pp_summary fmt t =
  let env = t.environment in
  Format.fprintf fmt "Deployment Plan (experimental)@\n";
  Format.fprintf fmt "workspace:   %s@\n" t.workspace;
  Format.fprintf fmt "environment: %s (%s)@\n" env.name (mode_to_string env.mode);
  Format.fprintf fmt "registry:    %s@\n" env.registry;
  Format.fprintf fmt "tag:         %s@\n" env.image_tag;
  Format.fprintf fmt "@\n";
  Format.fprintf fmt "services:@\n";
  List.iter (fun (s : service_spec) ->
    let rollout_strategy =
      s
      |> effective_rollout_strategy
      |> effective_rollout_strategy_to_string
    in
    Format.fprintf fmt "  [%s] %s/%s    rollout=%s -> %s@\n"
      (prim_to_string s.primitive) s.domain s.source_name rollout_strategy s.image
  ) t.services;
  (match t.topics with
   | []     -> ()
   | topics ->
     Format.fprintf fmt "@\n";
     Format.fprintf fmt "topics:   %s@\n" (String.concat ", " topics));
  (match t.migrations with
   | [] -> ()
   | ms ->
     Format.fprintf fmt "@\n";
     Format.fprintf fmt "migrations:   %s@\n" (String.concat ", " ms));
  (match t.schema_subjects with
   | [] -> ()
   | ss ->
     Format.fprintf fmt "@\n";
     Format.fprintf fmt "schema subjects:  %s@\n" (String.concat ", " ss));
  (match t.consumer_groups with
   | [] -> ()
   | cgs ->
     Format.fprintf fmt "@\n";
     Format.fprintf fmt "consumer groups:  %s@\n" (String.concat ", " cgs))

let discover_schema_subjects = Sun_cli_workspace_scan.discover_schema_subjects
let discover_topics = Sun_cli_workspace_scan.discover_topics
let discover_migrations = Sun_cli_workspace_scan.discover_migrations

let derive_consumer_groups workspace services =
  List.filter_map (fun (s : service_spec) ->
    match s.primitive with
    | Worker -> Some (s.domain, s.source_name)
    | _      -> None
  ) services
  |> Sun_cli_workspace_scan.derive_consumer_groups workspace

let k8s_name_of name =
  Sun_cli_kubernetes_name.normalize name

let invalid_kubernetes_name ~field ~value message =
  Invalid_kubernetes_name { field; value; message }

let k8s_name_result name =
  Sun_cli_kubernetes_name.k8s_name_of_source name
  |> Result.map_error (invalid_kubernetes_name ~field:"k8s_name" ~value:name)

let namespace_result ~workspace ~domain =
  let value = Printf.sprintf "%s-%s" (k8s_name_of workspace) (k8s_name_of domain) in
  Sun_cli_kubernetes_name.make_namespace value
  |> Result.map_error (invalid_kubernetes_name ~field:"namespace" ~value)

let namespace_of ~workspace ~domain =
  match namespace_result ~workspace ~domain with
  | Ok namespace -> namespace
  | Error err ->
    failwith (match err with
      | Invalid_kubernetes_name { field; value; message } ->
        Printf.sprintf "invalid Kubernetes %s %S: %s" field value message
      | Toml_error toml -> Sun_cli_toml.parse_error_to_string toml)

let image_ref ~registry ~workspace ~k8s_name ~tag =
  Printf.sprintf "%s/%s/%s:%s" registry workspace (k8s_name_to_string k8s_name) tag

let plan_error_to_string = function
  | Toml_error err -> Sun_cli_toml.parse_error_to_string err
  | Invalid_kubernetes_name { field; value; message } ->
    Printf.sprintf "invalid Kubernetes %s %S: %s" field value message

let prim_of_manifest = function
  | Sun_cli_manifest.Svc    -> Svc
  | Sun_cli_manifest.Worker -> Worker
  | Sun_cli_manifest.Fn     -> Fn

let of_services_result ~workspace ~env services =
  let to_spec svc =
    let* k8s_name  = k8s_name_result svc.Sun_cli_manifest.name in
    let* namespace = namespace_result ~workspace ~domain:svc.Sun_cli_manifest.domain in
    let image     = image_ref ~registry:env.registry ~workspace ~k8s_name ~tag:env.image_tag in
    let primitive = prim_of_manifest svc.Sun_cli_manifest.prim in
    let* toml     =
      Sun_cli_toml.load_result (Filename.concat svc.Sun_cli_manifest.dir "sun.toml")
      |> Result.map_error (fun err -> Toml_error err)
    in
    let schedule  = match primitive with
      | Fn -> Some (Sun_cli_manifest.extract_schedule
                      ~dir:svc.Sun_cli_manifest.dir
                      ~name:svc.Sun_cli_manifest.name)
      | _  -> None
    in
    { domain                = svc.Sun_cli_manifest.domain
    ; source_name           = svc.Sun_cli_manifest.name
    ; k8s_name
    ; namespace
    ; primitive
    ; source_dir            = svc.Sun_cli_manifest.dir
    ; image
    ; config                = toml.Sun_cli_toml.env_config
    ; secrets               = List.map (fun key -> (key, "")) toml.Sun_cli_toml.secret_keys
    ; schedule
    ; replicas              = Option.value toml.Sun_cli_toml.replicas ~default:1
    ; cpu                   = Option.value toml.Sun_cli_toml.cpu      ~default:"100m"
    ; memory                = Option.value toml.Sun_cli_toml.memory   ~default:"128Mi"
    ; rollout_strategy      = toml.Sun_cli_toml.rollout_strategy
    ; ingress_host          = toml.Sun_cli_toml.ingress_host
    ; ingress_path          = toml.Sun_cli_toml.ingress_path
    ; extra_labels          = toml.Sun_cli_toml.extra_labels
    ; progressive_delivery  = toml.Sun_cli_toml.progressive_delivery
    } |> Result.ok
  in
  let rec collect acc = function
    | [] -> Ok (List.rev acc)
    | svc :: rest ->
      let* spec = to_spec svc in
      collect (spec :: acc) rest
  in
  let* resolved_services = collect [] services in
  Ok { workspace
     ; environment    = env
     ; services       = resolved_services
     ; topics         = discover_topics ()
     ; migrations     = discover_migrations ()
     ; schema_subjects = discover_schema_subjects ()
     ; consumer_groups = derive_consumer_groups workspace resolved_services
     }

let of_services ~workspace ~env services =
  match of_services_result ~workspace ~env services with
  | Ok plan -> plan
  | Error err -> failwith (plan_error_to_string err)

let render_common_fields (s : service_spec) : Sun_cli_deployment_render.common_fields =
  { namespace  = s.namespace
  ; k8s_name   = s.k8s_name
  ; spec_image = s.image
  ; config     = s.config
  ; secrets    = s.secrets
  }

let render_deployment_fields (s : service_spec) : Sun_cli_deployment_render.deployment_fields =
  { replicas             = s.replicas
  ; cpu                  = s.cpu
  ; memory               = s.memory
  ; rollout_strategy     = s.rollout_strategy
  ; extra_labels         = s.extra_labels
  ; progressive_delivery = s.progressive_delivery
  }

let render_workload (s : service_spec) : Sun_cli_deployment_render.workload =
  let deployment = render_deployment_fields s in
  match s.primitive with
  | Svc ->
    Sun_cli_deployment_render.Render_svc
      { deployment; ingress_host = s.ingress_host; ingress_path = s.ingress_path }
  | Worker ->
    Sun_cli_deployment_render.Render_worker { deployment }
  | Fn ->
    let schedule = Option.value s.schedule ~default:"0 * * * *" in
    Sun_cli_deployment_render.Render_fn { schedule }

let render_spec ?(image = "") ?(secret_backend = Sun_cli_manifest.Kubernetes_live) s =
  let spec : Sun_cli_deployment_render.spec =
    { common   = render_common_fields s
    ; workload = render_workload s
    }
  in
  Sun_cli_deployment_render.render_spec ~image ~secret_backend spec
(** See [Sun_cli_deployment_render.render_spec] for the error contract. *)
