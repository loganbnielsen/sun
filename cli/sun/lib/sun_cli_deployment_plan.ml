type deployment_mode = Local | Customer_cloud | Sun_hosted

type env_config = {
  name           : string;
  mode           : deployment_mode;
  registry       : string;
  image_tag      : string;
  region         : string option;
  base_domain    : string option;
  secret_backend : string;
}

type primitive = Svc | Worker | Fn

type service_spec = {
  domain                : string;
  source_name           : string;
  k8s_name              : string;
  namespace             : string;
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

let mode_to_string = function
  | Local          -> "local"
  | Customer_cloud -> "customer_cloud"
  | Sun_hosted     -> "sun_hosted"

let prim_to_string = function
  | Svc    -> "svc"
  | Worker -> "worker"
  | Fn     -> "fn"

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
  let rollout_strategy_string s =
    match s.progressive_delivery with
    | Some (Sun_cli_toml.Canary _)  -> "canary"
    | Some Sun_cli_toml.Blue_green  -> "blue_green"
    | None ->
      (match s.rollout_strategy with
       | Some Sun_cli_toml.Recreate     -> "recreate"
       | Some Sun_cli_toml.RollingUpdate
       | None                           -> "rolling_update")
  in
  let ingress_json s =
    match s.ingress_host with
    | None      -> `Null
    | Some host ->
      let path = Option.value s.ingress_path ~default:"/" in
      `Assoc [ "host", `String host; "path", `String path ]
  in
  let service_to_json (s : service_spec) =
    `Assoc [
      "k8s_name",    `String s.k8s_name;
      "domain",      `String s.domain;
      "source_name", `String s.source_name;
      "namespace",   `String s.namespace;
      "primitive",   `String (prim_to_string s.primitive);
      "image",       `String s.image;
      "config",      `Assoc (List.map (fun (k, v) -> (k, `String v)) s.config);
      "secret_keys", `List  (List.map (fun (k, _) -> `String k) s.secrets);
      "schedule",    opt_string s.schedule;
      "replicas",    `Int    s.replicas;
      "cpu",         `String s.cpu;
      "memory",      `String s.memory;
      "rollout_strategy",     `String (rollout_strategy_string s);
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
      "secret_backend", `String env.secret_backend;
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
    Format.fprintf fmt "  [%s] %s/%s    -> %s@\n"
      (prim_to_string s.primitive) s.domain s.source_name s.image
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

(** Thin wrapper around [Sun_cli_workspace_model.discover_schema_subjects].
    Kept for backward-compatibility with callers that use the unit-argument form. *)
let discover_schema_subjects () =
  fst (Sun_cli_workspace_model.discover_schema_subjects ~dir:".")

(** Derive consumer group identifiers for all Worker service specs.
    Convention: ["<workspace>.<domain>.<worker_name>"]. *)
let derive_consumer_groups workspace services =
  List.filter_map (fun (s : service_spec) ->
    match s.primitive with
    | Worker -> Some (Printf.sprintf "%s.%s.%s" workspace s.domain s.source_name)
    | _      -> None
  ) services
  |> List.sort_uniq String.compare

(** Thin wrapper around [Sun_cli_workspace_model.discover_topics].
    Kept for backward-compatibility with callers that use the unit-argument form. *)
let discover_topics () =
  fst (Sun_cli_workspace_model.discover_topics ~dir:".")

(** Thin wrapper around [Sun_cli_workspace_model.discover_migrations].
    Kept for backward-compatibility with callers that use the unit-argument form. *)
let discover_migrations () =
  fst (Sun_cli_workspace_model.discover_migrations ~dir:".")

let k8s_name_of name =
  String.map (fun c -> if c = '_' then '-' else c)
    (String.lowercase_ascii name)

let namespace_of ~workspace ~domain =
  Printf.sprintf "%s-%s" (k8s_name_of workspace) (k8s_name_of domain)

let image_ref ~registry ~workspace ~k8s_name ~tag =
  Printf.sprintf "%s/%s/%s:%s" registry workspace k8s_name tag

let prim_of_manifest = function
  | Sun_cli_manifest.Svc    -> Svc
  | Sun_cli_manifest.Worker -> Worker
  | Sun_cli_manifest.Fn     -> Fn

let of_services ~workspace ~env services =
  let to_spec svc =
    let k8s_name  = k8s_name_of svc.Sun_cli_manifest.name in
    let namespace = namespace_of ~workspace ~domain:svc.Sun_cli_manifest.domain in
    let image     = image_ref ~registry:env.registry ~workspace ~k8s_name ~tag:env.image_tag in
    let primitive = prim_of_manifest svc.Sun_cli_manifest.prim in
    let toml      = Sun_cli_toml.load (Filename.concat svc.Sun_cli_manifest.dir "sun.toml") in
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
    }
  in
  let resolved_services = List.map to_spec services in
  let inv = Sun_cli_workspace_model.scan ~dir:"." in
  { workspace
  ; environment    = env
  ; services       = resolved_services
  ; topics         = inv.topics
  ; migrations     = inv.migrations
  ; schema_subjects = inv.schema_subjects
  ; consumer_groups = derive_consumer_groups workspace resolved_services
  }

(** Render a (namespace_yaml, workload_yaml) pair from a resolved [service_spec].
    All deployment identity fields (namespace, k8s name, image, primitive,
    config, secrets, schedule, replicas, cpu, memory, rollout_strategy,
    ingress_host, ingress_path, extra_labels, progressive_delivery) come from [spec].
    Pass [~image] to override [spec.image] — used by [sun up] where the
    dry-run display image (localhost:5000) differs from the cluster image.

    When [spec.progressive_delivery] is [Some _], the workload section emits an
    Argo [Rollout] resource instead of a standard [Deployment].  Blue-green also
    emits two Service resources ([<name>-active] and [<name>-preview]) instead of
    the single ClusterIP [Service] used by the default path. *)
let render_spec ?(image = "") ?(secret_backend = Sun_cli_manifest.Kubernetes_live) spec =
  let ns               = spec.namespace in
  let name             = spec.k8s_name in
  let img              = if image = "" then spec.image else image in
  let replicas         = spec.replicas in
  let cpu              = spec.cpu in
  let memory           = spec.memory in
  let rollout_strategy = Option.value spec.rollout_strategy
                           ~default:Sun_cli_toml.RollingUpdate in
  let extra_labels     = spec.extra_labels in
  let ingress_host     = Option.value spec.ingress_host ~default:"" in
  let ingress_path     = Option.value spec.ingress_path ~default:"/" in
  let cfg_hash         = Sun_cli_manifest.config_hash spec.config in
  Sun_cli_manifest.(
    let ns_yaml = namespace_doc ns in
    let workload_yaml =
      (* Build the secret resource document depending on backend:
         - Kubernetes_live (default): emit a Secret with real values (sun up / live deploy).
         - Kubernetes_placeholder: emit a Secret with empty stringData (GitOps fill-in).
         - External_secrets _: emit an ExternalSecret CRD so ESO materialises the Secret. *)
      let secret_resource = match secret_backend with
        | Kubernetes_live ->
          let value_from_env key =
            match Sys.getenv_opt key with
            | Some value -> value
            | None       -> ""
          in
          let extra_secrets =
            List.map (fun (k, _) -> (k, value_from_env k)) spec.secrets
          in
          let base_secrets =
            List.map (fun (k, _) -> (k, value_from_env k)) default_secrets
          in
          secret_doc ~base_secrets ~extra_secrets ns name
        | Kubernetes_placeholder ->
          let extra_secrets = List.map (fun (k, _) -> (k, "")) spec.secrets in
          secret_doc ~extra_secrets ~redact:true ns name
        | External_secrets { store_ref; store_kind; key_prefix; refresh_interval } ->
          let all_keys =
            List.map fst default_secrets @ List.map fst spec.secrets
          in
          external_secret_doc ~store_ref ~store_kind ~key_prefix ~refresh_interval
            ~secret_keys:all_keys ns name
      in
      let common = [
        service_account_doc ns name;
        configmap_doc ~extra_env:spec.config ns name;
        secret_resource;
        network_policy_doc ns name;
      ] in
      let resources = match spec.primitive, spec.progressive_delivery with
        (* ── Argo Rollouts paths ─────────────────────────────────────────── *)
        | (Svc | Worker), Some pd ->
          let ports  = spec.primitive = Svc in
          let probes = spec.primitive = Svc in
          let rollout = rollout_doc ~extra_labels ~secret_keys:(List.map fst spec.secrets) ~config_hash:cfg_hash ~ports ~probes ~replicas ~cpu ~memory ns name img pd in
          (match pd with
           | Sun_cli_toml.Blue_green ->
             (* Blue-green needs active + preview services instead of one service *)
             let is_svc = spec.primitive = Svc in
             [ rollout
             ; blue_green_service_docs ns name
             ; (if is_svc then ingress_doc ~ingress_host ~ingress_path ns (name ^ "-active")
                else "")
             ]
             |> List.filter (fun s -> s <> "")
           | Sun_cli_toml.Canary _ ->
             let svc    = if ports then [service_doc ns name] else [] in
             let ingr   = if ports then [ingress_doc ~ingress_host ~ingress_path ns name] else [] in
             [ rollout ] @ svc @ ingr)
        (* ── Standard Deployment paths ────────────────────────────────────── *)
        | Svc, None ->
          [ deployment_doc ~rollout_strategy ~extra_labels ~config_hash:cfg_hash
              ~secret_keys:(List.map fst spec.secrets)
              ~ports:true ~probes:true ~replicas ~cpu ~memory ns name img
          ; service_doc ns name
          ; ingress_doc ~ingress_host ~ingress_path ns name ]
        | Worker, None ->
          [ deployment_doc ~rollout_strategy ~extra_labels ~config_hash:cfg_hash
              ~secret_keys:(List.map fst spec.secrets)
              ~ports:false ~probes:false ~replicas ~cpu ~memory ns name img ]
        | Fn, _ ->
          let schedule = Option.value spec.schedule ~default:"0 * * * *" in
          [ cronjob_doc ~secret_keys:(List.map fst spec.secrets) ns name img schedule ]
      in
      String.concat "\n" (common @ resources)
    in
    (ns_yaml, workload_yaml)
  )
