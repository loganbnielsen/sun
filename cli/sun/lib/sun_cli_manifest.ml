(* YAML manifest rendering and apply logic shared by sun up and sun deploy. *)

(* ── Secret backend type ─────────────────────────────────────────────────── *)

type secret_backend =
  | Kubernetes_live         (** Emit a Kubernetes Secret with real values (live deploy / sun up). *)
  | Kubernetes_placeholder  (** Emit a redacted Kubernetes Secret with empty stringData (GitOps). *)
  | External_secrets of {
      store_ref        : string;  (* e.g. "aws-secrets-manager" *)
      store_kind       : string;  (* e.g. "ClusterSecretStore" *)
      key_prefix       : string;  (* e.g. "myworkspace/" *)
      refresh_interval : string;  (* e.g. "1h" *)
    }

(* ── Service model ───────────────────────────────────────────────────────── *)

type primitive = Svc | Worker | Fn

type service = {
  domain : string;
  name   : string;   (* directory name, e.g. "charge_svc" *)
  prim   : primitive;
  dir    : string;   (* relative path from workspace root, e.g. "app/payments/charge_svc" *)
}

let prim_of_suffix name =
  let n = String.length name in
  if   n > 4 && String.sub name (n-4) 4 = "_svc"    then Some Svc
  else if n > 7 && String.sub name (n-7) 7 = "_worker" then Some Worker
  else if n > 3 && String.sub name (n-3) 3 = "_fn"     then Some Fn
  else None

let prim_label = function Svc -> "svc" | Worker -> "worker" | Fn -> "fn"

(* ── Service discovery ───────────────────────────────────────────────────── *)

let discover_services ~filter_path =
  let app_dir = "app" in
  if not (Sys.file_exists app_dir && Sys.is_directory app_dir) then begin
    Printf.eprintf "error: 'app/' not found — run from the workspace root.\n";
    exit 1
  end;
  let services = ref [] in
  (try
    Array.iter (fun domain ->
      let dp = Filename.concat app_dir domain in
      if domain.[0] <> '.' && Sys.is_directory dp then
        (try
          Array.iter (fun svc_dir ->
            let sp = Filename.concat dp svc_dir in
            if svc_dir.[0] <> '.' && Sys.is_directory sp then
              match prim_of_suffix svc_dir with
              | None -> ()
              | Some prim ->
                if Sys.file_exists (Filename.concat sp "Dockerfile") then begin
                  let svc = { domain; name = svc_dir; prim; dir = sp } in
                  let included = match filter_path with
                    | None   -> true
                    | Some p -> sp = p || Filename.basename sp = p
                  in
                  if included then services := svc :: !services
                end
          ) (Sys.readdir dp)
        with _ -> ())
    ) (Sys.readdir app_dir)
  with _ -> ());
  List.rev !services

(* ── Schedule extraction for -fn ─────────────────────────────────────────── *)

let extract_schedule ~dir ~name =
  let base =
    let n = String.length name in
    String.sub name 0 (n - 3)
  in
  let candidates = [
    Filename.concat dir (Printf.sprintf "lib/%s_fn.ml" base);
    Filename.concat dir (Printf.sprintf "lib/%s.ml"    base);
    Filename.concat dir (Printf.sprintf "bin/%s.ml"    base);
  ] in
  let marker = {|schedule = "|} in
  let ml = String.length marker in
  let try_file path =
    if not (Sys.file_exists path) then None
    else begin
      let ic = open_in path in
      let content = In_channel.input_all ic in
      close_in ic;
      let sl = String.length content in
      let found = ref None in
      for i = 0 to sl - ml - 1 do
        if !found = None && String.sub content i ml = marker then begin
          let j = ref (i + ml) in
          while !j < sl && content.[!j] <> '"' do incr j done;
          found := Some (String.sub content (i + ml) (!j - i - ml))
        end
      done;
      !found
    end
  in
  let rec go = function
    | []        -> "0 * * * *"
    | p :: rest -> (match try_file p with Some s -> s | None -> go rest)
  in
  go candidates

(* ── Structured manifest model ───────────────────────────────────────────── *)

(* Typed YAML value.
   [Str] emits a bare scalar (safe for identifiers, API versions, names).
   [Quoted] emits a JSON-encoded double-quoted string, safe for arbitrary data
   (env values, schedules, config hashes, labels with special characters). *)
type value =
  | Str    of string
  | Quoted of string
  | Int    of int
  | Bool   of bool
  | Map    of (string * value) list
  | Seq    of value list

(* Emit [v] as a YAML block scalar or block collection at [indent] spaces.
   [Map] fields render as [key: scalar] or [key:\n  nested] lines.
   [Seq] items render as [- scalar] or [- firstkey: val\n  restkeys…].
   This matches the indentation style of the previous Printf.sprintf templates. *)
let rec to_yaml ?(indent = 0) v =
  let sp = String.make indent ' ' in
  match v with
  | Str s    -> s
  | Quoted s -> Yojson.Safe.to_string (`String s)
  | Int n    -> string_of_int n
  | Bool b   -> if b then "true" else "false"
  | Map []   -> "{}"
  | Seq []   -> "[]"
  | Map kv   ->
    String.concat "\n" (List.map (fun (k, fv) ->
      match fv with
      | Map [] -> sp ^ k ^ ": {}"
      | Seq [] -> sp ^ k ^ ": []"
      | Map _ | Seq _ ->
        sp ^ k ^ ":\n" ^ to_yaml ~indent:(indent + 2) fv
      | _ ->
        sp ^ k ^ ": " ^ to_yaml ~indent:(indent + 2) fv
    ) kv)
  | Seq vs ->
    String.concat "\n" (List.map (fun item ->
      match item with
      | Map ((fk, fv) :: rest) ->
        (* First field rides the "- " line; subsequent fields are body. *)
        let first =
          match fv with
          | Map [] -> sp ^ "- " ^ fk ^ ": {}"
          | Seq [] -> sp ^ "- " ^ fk ^ ": []"
          | Map _ | Seq _ ->
            sp ^ "- " ^ fk ^ ":\n" ^ to_yaml ~indent:(indent + 4) fv
          | _ ->
            sp ^ "- " ^ fk ^ ": " ^ to_yaml ~indent:0 fv
        in
        if rest = [] then first
        else first ^ "\n" ^ to_yaml ~indent:(indent + 2) (Map rest)
      | Map [] -> sp ^ "- {}"
      | _      -> sp ^ "- " ^ to_yaml ~indent:0 item
    ) vs)

(* Wrap a resource value as a YAML document string (starts with "---"). *)
let to_doc ?(indent = 0) v = "---\n" ^ to_yaml ~indent v

(* ── Default environment and credentials ────────────────────────────────── *)

let default_cluster_env = [
  "KAFKA_BROKERS",       "redpanda.redpanda.svc.cluster.local:9093";
  "SCHEMA_REGISTRY_URL", "http://redpanda.redpanda.svc.cluster.local:8081";
  "REDPANDA_ADMIN_URL",  "http://redpanda.redpanda.svc.cluster.local:9644";
  "LOKI_URL",            "http://loki.monitoring.svc.cluster.local:3100";
  "PUSHGATEWAY_URL",     "http://prometheus-prometheus-pushgateway.monitoring.svc.cluster.local:9091";
]

let default_secrets = [
  "POSTGRES_URL", "";
]

let runtime_secret_name = "sun-secrets"

let f = Printf.sprintf

let config_hash extra_env =
  default_cluster_env @ extra_env
  |> List.map (fun (k, v) -> k ^ "=" ^ v)
  |> String.concat "\n"
  |> Digest.string
  |> Digest.to_hex

(* Render a [(key, value)] env list as YAML mapping lines under a parent key.
   Values are always Quoted so empty strings, URLs, and multi-word strings
   are safely encoded without raw interpolation. *)
let env_map pairs =
  Map (List.map (fun (k, v) -> k, Quoted v) pairs)

(* ── Simple resource builders ────────────────────────────────────────────── *)

let namespace_doc ns =
  to_doc (Map [
    "apiVersion", Str "v1";
    "kind",       Str "Namespace";
    "metadata",   Map ["name", Str ns];
  ])

let service_account_doc ns name =
  to_doc (Map [
    "apiVersion", Str "v1";
    "kind",       Str "ServiceAccount";
    "metadata",   Map ["name", Str name; "namespace", Str ns];
  ])

let configmap_doc ?(extra_env = []) ns name =
  let env = default_cluster_env @ extra_env in
  to_doc (Map [
    "apiVersion", Str "v1";
    "kind",       Str "ConfigMap";
    "metadata",   Map ["name", Str (name ^ "-env"); "namespace", Str ns];
    "data",       env_map env;
  ])

(* Credentials are emitted as a Secret with stringData so operators can fill
   in real values without base64 encoding. Kubernetes converts to base64 on apply.
   In GitOps mode (~redact:true) all values are stripped to "" so nothing sensitive
   appears in committed manifests; operators must populate values before applying. *)
let secret_doc ?(base_secrets = default_secrets) ?(extra_secrets = []) ?(redact = false) ns name =
  let secrets = base_secrets @ extra_secrets in
  let secrets = if redact then List.map (fun (k, _) -> (k, "")) secrets else secrets in
  let comment = if redact then
    "# Populate these values before applying.\n\
     # Use `sun secret set <KEY> --env <env>` or your secrets manager.\n"
  else "" in
  (* Comment must be inside the document block (after ---) so consumers that
     split on document boundaries still find it in the Secret block. *)
  "---\n" ^ comment ^
  to_yaml (Map [
    "apiVersion", Str "v1";
    "kind",       Str "Secret";
    "metadata",   Map ["name", Str (name ^ "-secrets"); "namespace", Str ns];
    "type",       Str "Opaque";
    "stringData", env_map secrets;
  ])

(* Emits an ExternalSecret resource (External Secrets Operator v1beta1).
   secret_keys must be the full list of all keys (default_secrets keys + spec.secrets keys). *)
let external_secret_doc ~store_ref ~store_kind ~key_prefix ~refresh_interval ~secret_keys ns name =
  let remote_refs = Seq (List.map (fun key ->
    Map [
      "secretKey", Str key;
      "remoteRef", Map ["key", Str (key_prefix ^ key)];
    ]
  ) secret_keys) in
  to_doc (Map [
    "apiVersion", Str "external-secrets.io/v1beta1";
    "kind",       Str "ExternalSecret";
    "metadata",   Map ["name", Str (name ^ "-secrets"); "namespace", Str ns];
    "spec",       Map [
      "refreshInterval", Str refresh_interval;
      "secretStoreRef",  Map ["name", Str store_ref; "kind", Str store_kind];
      "target",          Map ["name", Str (name ^ "-secrets"); "creationPolicy", Str "Owner"];
      "data",            remote_refs;
    ];
  ])

let service_doc ns name =
  to_doc (Map [
    "apiVersion", Str "v1";
    "kind",       Str "Service";
    "metadata",   Map ["name", Str name; "namespace", Str ns];
    "spec",       Map [
      "type",     Str "ClusterIP";
      "selector", Map ["app", Str name];
      "ports",    Seq [Map ["port", Int 80; "targetPort", Int 8080]];
    ];
  ])

let ingress_doc ?(ingress_host = "") ?(ingress_path = "/") ns name =
  let rule_meta = if ingress_host = "" then []
    else ["host", Str ingress_host]
  in
  to_doc (Map [
    "apiVersion", Str "networking.k8s.io/v1";
    "kind",       Str "Ingress";
    "metadata",   Map [
      "name",        Str name;
      "namespace",   Str ns;
      "annotations", Map ["nginx.ingress.kubernetes.io/ssl-redirect", Quoted "true"];
    ];
    "spec", Map [
      "rules", Seq [Map (rule_meta @ [
        "http", Map [
          "paths", Seq [Map [
            "path",     Str ingress_path;
            "pathType", Str "Prefix";
            "backend",  Map [
              "service", Map [
                "name", Str name;
                "port", Map ["number", Int 80];
              ];
            ];
          ]];
        ];
      ])];
    ];
  ])

let network_policy_doc ns name =
  to_doc (Map [
    "apiVersion", Str "networking.k8s.io/v1";
    "kind",       Str "NetworkPolicy";
    "metadata",   Map ["name", Str (name ^ "-netpol"); "namespace", Str ns];
    "spec",       Map [
      "podSelector", Map ["matchLabels", Map ["app", Str name]];
      "policyTypes", Seq [Str "Ingress"; Str "Egress"];
      "ingress",     Seq [Map ["from", Seq [
        Map ["namespaceSelector", Map ["matchLabels",
               Map ["kubernetes.io/metadata.name", Str "ingress-nginx"]]];
        Map ["podSelector", Map []];
      ]]];
      "egress", Seq [
        Map ["ports", Seq [
          Map ["port", Int 53; "protocol", Str "UDP"];
          Map ["port", Int 53; "protocol", Str "TCP"];
        ]];
        Map ["to", Seq [
          Map ["namespaceSelector", Map ["matchLabels",
                 Map ["kubernetes.io/metadata.name", Str "redpanda"]]];
          Map ["namespaceSelector", Map ["matchLabels",
                 Map ["kubernetes.io/metadata.name", Str "postgresql"]]];
          Map ["namespaceSelector", Map ["matchLabels",
                 Map ["kubernetes.io/metadata.name", Str "monitoring"]]];
        ]];
      ];
    ];
  ])

(* ── Shared pod / container builders ────────────────────────────────────── *)

(* Reused across Deployment, Rollout (argoproj), and CronJob. *)

let pod_security_context = Map [
  "runAsNonRoot",   Bool true;
  "runAsUser",      Int 65534;
  "runAsGroup",     Int 65534;
  "seccompProfile", Map ["type", Str "RuntimeDefault"];
]

let container_security_context = Map [
  "allowPrivilegeEscalation", Bool false;
  "readOnlyRootFilesystem",   Bool true;
]

let http_probe = Map [
  "httpGet",             Map ["path", Str "/healthz"; "port", Int 8080];
  "initialDelaySeconds", Int 5;
  "periodSeconds",       Int 10;
]

(* Builds the container field list.  Port, probe, and secret-key fields are
   optional; all three workload kinds (Deployment, Rollout, CronJob) share this
   builder so changes to container structure propagate everywhere. *)
let container_fields ~name ~image ~cpu ~memory ~ports ~probes ~secret_keys =
  [ "name",            Str name
  ; "image",           Str image
  ; "imagePullPolicy", Str "Always"
  ; "securityContext", container_security_context
  ]
  @ (if ports then ["ports", Seq [Map ["containerPort", Int 8080]]] else [])
  @ (if probes then ["livenessProbe", http_probe; "readinessProbe", http_probe] else [])
  @ (match secret_keys with
     | [] -> []
     | keys -> ["env", Seq (List.map (fun k ->
         Map [ "name", Str k
             ; "valueFrom", Map ["secretKeyRef",
                 Map ["name", Str (name ^ "-secrets"); "key", Str k]]
             ]
       ) keys)])
  @ [ "envFrom", Seq [
        Map ["configMapRef", Map ["name", Str (name ^ "-env")]]
      ; Map ["secretRef",    Map ["name", Str (name ^ "-secrets")]]
      ]
    ; "resources", Map [
        "requests", Map ["cpu", Str cpu; "memory", Str memory]
      ; "limits",   Map ["cpu", Str cpu; "memory", Str memory]
      ]
    ]

(* Shared pod template spec (metadata + spec) for Deployment and Rollout.
   [extra_labels] and [config_hash] are the same for both workload kinds. *)
let pod_template ~name ~image ~cpu ~memory ~config_hash ~extra_labels ~secret_keys ~ports ~probes =
  let base_labels = ["app", Str name] in
  let all_labels  = base_labels @ List.map (fun (k, v) -> k, Quoted v) extra_labels in
  Map [
    "metadata", Map [
      "labels",      Map all_labels;
      "annotations", Map ["sun.dev/config-hash", Quoted config_hash];
    ];
    "spec", Map [
      "serviceAccountName", Str name;
      "securityContext",    pod_security_context;
      "containers",         Seq [Map (container_fields ~name ~image ~cpu ~memory ~ports ~probes ~secret_keys)];
    ];
  ]

(* ── Workload-specific builders ─────────────────────────────────────────── *)

let deployment_doc ?(rollout_strategy = Sun_cli_toml.RollingUpdate)
                   ?(extra_labels = [])
                   ?(secret_keys = [])
                   ?(config_hash = "")
                   ~ports ~probes ~replicas ~cpu ~memory ns name image =
  let strategy_type = match rollout_strategy with
    | Sun_cli_toml.Recreate      -> "Recreate"
    | Sun_cli_toml.RollingUpdate -> "RollingUpdate"
  in
  to_doc (Map [
    "apiVersion", Str "apps/v1";
    "kind",       Str "Deployment";
    "metadata",   Map ["name", Str name; "namespace", Str ns];
    "spec",       Map [
      "replicas",  Int replicas;
      "strategy",  Map ["type", Str strategy_type];
      "selector",  Map ["matchLabels", Map ["app", Str name]];
      "template",  pod_template ~name ~image ~cpu ~memory ~config_hash ~extra_labels ~secret_keys ~ports ~probes;
    ];
  ])

(* ── Argo Rollouts ───────────────────────────────────────────────────────── *)

let canary_strategy steps =
  let step_items = List.map (function
    | Sun_cli_toml.Weight n    -> Map ["setWeight", Int n]
    | Sun_cli_toml.Pause None  -> Map ["pause", Map []]
    | Sun_cli_toml.Pause (Some d) -> Map ["pause", Map ["duration", Int d]]
  ) steps in
  Map ["canary", Map ["steps", Seq step_items]]

let blue_green_strategy name =
  Map ["blueGreen", Map [
    "activeService",       Str (name ^ "-active");
    "previewService",      Str (name ^ "-preview");
    "autoPromotionEnabled", Bool false;
  ]]

(** [rollout_doc] renders an Argo Rollout resource.  The pod template is shared
    with [deployment_doc] via [pod_template]; only apiVersion, kind, and the
    strategy section differ. *)
let rollout_doc ?(extra_labels = []) ?(secret_keys = []) ?(config_hash = "")
                ~ports ~probes ~replicas ~cpu ~memory ns name image pd =
  let strategy = match pd with
    | Sun_cli_toml.Canary { steps } -> canary_strategy steps
    | Sun_cli_toml.Blue_green       -> blue_green_strategy name
  in
  to_doc (Map [
    "apiVersion", Str "argoproj.io/v1alpha1";
    "kind",       Str "Rollout";
    "metadata",   Map ["name", Str name; "namespace", Str ns];
    "spec",       Map [
      "replicas",  Int replicas;
      "selector",  Map ["matchLabels", Map ["app", Str name]];
      "template",  pod_template ~name ~image ~cpu ~memory ~config_hash ~extra_labels ~secret_keys ~ports ~probes;
      "strategy",  strategy;
    ];
  ])

(** Two ClusterIP Services required by the blue-green strategy. *)
let blue_green_service_docs ns name =
  let make_svc svc_name =
    to_doc (Map [
      "apiVersion", Str "v1";
      "kind",       Str "Service";
      "metadata",   Map ["name", Str svc_name; "namespace", Str ns];
      "spec",       Map [
        "type",     Str "ClusterIP";
        "selector", Map ["app", Str name];
        "ports",    Seq [Map ["port", Int 80; "targetPort", Int 8080]];
      ];
    ])
  in
  make_svc (name ^ "-active") ^ "\n" ^ make_svc (name ^ "-preview")

let cronjob_doc ?(secret_keys = []) ns name image schedule =
  to_doc (Map [
    "apiVersion", Str "batch/v1";
    "kind",       Str "CronJob";
    "metadata",   Map ["name", Str name; "namespace", Str ns];
    "spec",       Map [
      "schedule",    Quoted schedule;
      "jobTemplate", Map [
        "spec", Map [
          "backoffLimit", Int 3;
          "template",     Map [
            "metadata", Map ["labels", Map ["app", Str name]];
            "spec", Map [
              "serviceAccountName", Str name;
              "restartPolicy",      Str "OnFailure";
              "securityContext",    pod_security_context;
              "containers", Seq [Map (container_fields
                ~name ~image ~cpu:"100m" ~memory:"128Mi"
                ~ports:false ~probes:false ~secret_keys)];
            ];
          ];
        ];
      ];
    ];
  ])

let render ?(toml = Sun_cli_toml.empty) svc ~ns ~name ~image =
  let replicas         = Option.value toml.replicas ~default:1 in
  let cpu              = Option.value toml.cpu      ~default:"100m" in
  let memory           = Option.value toml.memory   ~default:"128Mi" in
  let rollout_strategy = Option.value toml.rollout_strategy
                           ~default:Sun_cli_toml.RollingUpdate in
  let progressive_delivery = toml.progressive_delivery in
  let extra_labels     = toml.extra_labels in
  let ingress_host     = Option.value toml.ingress_host ~default:"" in
  let ingress_path     = Option.value toml.ingress_path ~default:"/" in
  let config_hash      = config_hash toml.env_config in
  let ns_yaml = namespace_doc ns in
  let workload_yaml =
    let extra_secrets = List.map (fun k -> (k, "")) toml.Sun_cli_toml.secret_keys in
    let common = [
      service_account_doc ns name;
      configmap_doc ~extra_env:toml.env_config ns name;
      secret_doc ~extra_secrets ns name;
      network_policy_doc ns name;
    ] in
    let resources = match svc.prim, progressive_delivery with
      | (Svc | Worker), Some pd ->
        let ports  = svc.prim = Svc in
        let probes = svc.prim = Svc in
        let rollout = rollout_doc ~extra_labels ~secret_keys:toml.Sun_cli_toml.secret_keys ~config_hash ~ports ~probes ~replicas ~cpu ~memory ns name image pd in
        (match pd with
         | Sun_cli_toml.Blue_green ->
           [ rollout
           ; blue_green_service_docs ns name
           ; (if ports then ingress_doc ~ingress_host ~ingress_path ns (name ^ "-active") else "")
           ]
           |> List.filter (fun s -> s <> "")
         | Sun_cli_toml.Canary _ ->
           let svc_doc = if ports then [service_doc ns name] else [] in
           let ingr    = if ports then [ingress_doc ~ingress_host ~ingress_path ns name] else [] in
           [ rollout ] @ svc_doc @ ingr)
      | Svc, None ->
        [ deployment_doc ~rollout_strategy ~extra_labels ~config_hash
            ~ports:true ~probes:true ~replicas ~cpu ~memory ns name image
        ; service_doc ns name
        ; ingress_doc ~ingress_host ~ingress_path ns name ]
      | Worker, None ->
        [ deployment_doc ~rollout_strategy ~extra_labels ~config_hash
            ~ports:false ~probes:false ~replicas ~cpu ~memory ns name image ]
      | Fn, _ ->
        let schedule = extract_schedule ~dir:svc.dir ~name:svc.name in
        [ cronjob_doc ns name image schedule ]
    in
    String.concat "\n" (common @ resources)
  in
  (ns_yaml, workload_yaml)

(* ── Apply / emit helpers ────────────────────────────────────────────────── *)

exception Deploy_failed of string

let write_tmp content =
  let tmp = Filename.temp_file "sun-manifest-" ".yaml" in
  let oc = open_out tmp in
  output_string oc content;
  close_out oc;
  tmp

let apply_live yaml =
  let tmp = write_tmp yaml in
  let rc = Sys.command (f "kubectl apply -f %s" (Filename.quote tmp)) in
  Sys.remove tmp;
  if rc <> 0 then raise (Deploy_failed "kubectl apply failed")

let apply (ns_yaml, workload_yaml) ~dry_run =
  if dry_run then
    Printf.printf "%s\n%s\n" ns_yaml workload_yaml
  else begin
    apply_live ns_yaml;
    let tmp = write_tmp workload_yaml in
    (try
      let rc = Sys.command (f "kubectl apply -f %s --dry-run=server 2>&1" (Filename.quote tmp)) in
      if rc <> 0 then
        raise (Deploy_failed "kubectl server-side dry-run failed (invalid manifest)");
      let rc = Sys.command (f "kubectl apply -f %s" (Filename.quote tmp)) in
      if rc <> 0 then raise (Deploy_failed "kubectl apply failed")
    with e ->
      (try Sys.remove tmp with _ -> ());
      raise e);
    Sys.remove tmp
  end

(* Write YAML for one service to <dir>/<ns>-<name>.yaml.
   Used by sun deploy --emit-to for GitOps workflows. *)
let emit_to_dir dir (ns_yaml, workload_yaml) ~ns ~name =
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir (f "%s-%s.yaml" ns name) in
  let oc = open_out path in
  output_string oc ns_yaml;
  output_string oc "\n";
  output_string oc workload_yaml;
  output_string oc "\n";
  close_out oc;
  path
