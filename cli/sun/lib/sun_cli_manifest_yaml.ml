(* Pure YAML generators — no Sys.command, open_out, or Sys.readdir. *)

(* ── Service model ───────────────────────────────────────────────────────── *)

type primitive = Svc | Worker | Fn

type service = {
  domain : string;
  name   : string;
  primitive : primitive;
  dir    : string;
}

let primitive_label = function Svc -> "svc" | Worker -> "worker" | Fn -> "fn"

type workload_shape = Http_service | Background_worker

(* ── Schedule extraction for -fn ─────────────────────────────────────────── *)

let extract_schedule ~dir ~name:_ =
  (* Read schedule from the service's sun.toml [service] section.
     This replaces ad hoc substring scanning of OCaml source files,
     which produced false positives when "schedule = " appeared in
     comments or unrelated string literals.
     Default: "0 * * * *" (hourly) when sun.toml has no schedule. *)
  let toml_path = Filename.concat dir "sun.toml" in
  match Sun_cli_toml.load_result toml_path with
  | Ok { Sun_cli_toml.schedule = Some s; _ } -> s
  | Ok _  -> "0 * * * *"
  | Error _ -> "0 * * * *"

(* ── YAML templates ─────────────────────────────────────────────────────── *)

let default_cluster_env = [
  "KAFKA_BROKERS",       "redpanda.redpanda.svc.cluster.local:9093";
  "SCHEMA_REGISTRY_URL", "http://redpanda.redpanda.svc.cluster.local:8081";
  "REDPANDA_ADMIN_URL",  "http://redpanda.redpanda.svc.cluster.local:9644";
  "LOKI_URL",            "http://loki.monitoring.svc.cluster.local:3100";
  "PUSHGATEWAY_URL",     "http://prometheus-prometheus-pushgateway.monitoring.svc.cluster.local:9091";
]

(* Credentials that must never appear in ConfigMap — emitted as a Secret.
   Values are intentionally empty; operators must supply real values via the
   environment (POSTGRES_URL) or a secrets manager before applying. *)
let default_secrets = [
  "POSTGRES_URL", "";
]

let runtime_secret_name = "sun-secrets"

let f = Printf.sprintf

let render_env_block env =
  String.concat "\n" (List.map (fun (k, v) -> f "  %s: \"%s\"" k v) env)

let config_hash extra_env =
  default_cluster_env @ extra_env
  |> List.map (fun (k, v) -> k ^ "=" ^ v)
  |> String.concat "\n"
  |> Digest.string
  |> Digest.to_hex

let namespace_doc ~ns =
  f {|---
apiVersion: v1
kind: Namespace
metadata:
  name: %s|} ns

let service_account_doc ~ns ~name =
  f {|---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: %s
  namespace: %s|} name ns

let configmap_doc ?(extra_env = []) ~ns ~name () =
  let env = default_cluster_env @ extra_env in
  f {|---
apiVersion: v1
kind: ConfigMap
metadata:
  name: %s-env
  namespace: %s
data:
%s|} name ns (render_env_block env)

(* Credentials are emitted as a Secret with stringData so operators can fill
   in real values without base64 encoding. Kubernetes converts to base64 on apply.
   The Secret is named "<name>-secrets" (per-service) so each service owns its secret.
   In GitOps mode (~redact:true) all values are stripped to "" so nothing sensitive
   appears in committed manifests; operators must populate values before applying. *)
let secret_doc ?(base_secrets = default_secrets) ?(extra_secrets = []) ?(redact = false) ~ns ~name () =
  let secrets = base_secrets @ extra_secrets in
  let secrets = if redact then List.map (fun (k, _) -> (k, "")) secrets else secrets in
  let comment = if redact then
    "# Populate these values before applying.\n\
     # Use `sun secret set <KEY> --env <env>` or your secrets manager.\n"
  else "" in
  f {|---
apiVersion: v1
kind: Secret
metadata:
  name: %s-secrets
  namespace: %s
type: Opaque
%sstringData:
%s|} name ns comment (render_env_block secrets)

(* Emits an ExternalSecret resource (External Secrets Operator v1beta1).
   The ESO controller will materialise a Kubernetes Secret named "<name>-secrets"
   in the same namespace, which workload pods reference via envFrom secretRef.
   secret_keys must be the full list of all keys (default_secrets keys + spec.secrets keys). *)
let external_secret_doc ~store_ref ~store_kind ~key_prefix ~refresh_interval ~secret_keys ~ns ~name =
  let remote_refs =
    String.concat "\n" (List.map (fun key ->
      f {|  - secretKey: %s
    remoteRef:
      key: %s%s|} key key_prefix key
    ) secret_keys)
  in
  f {|---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: %s-secrets
  namespace: %s
spec:
  refreshInterval: %s
  secretStoreRef:
    name: %s
    kind: %s
  target:
    name: %s-secrets
    creationPolicy: Owner
  data:
%s|} name ns refresh_interval store_ref store_kind name remote_refs

let render_secret_key_refs ~name secret_keys =
  match secret_keys with
  | [] -> ""
  | keys ->
    "\n        env:\n" ^
    String.concat "\n" (List.map (fun key ->
      f {|        - name: %s
          valueFrom:
            secretKeyRef:
              name: %s-secrets
              key: %s|} key name key
    ) keys)

let render_extra_labels labels =
  (* Renders extra_labels as additional pod-template label lines (4-space indent). *)
  String.concat "\n" (List.map (fun (k, v) -> f "        %s: \"%s\"" k v) labels)

let deployment_doc ?(rollout_strategy = Sun_cli_toml.RollingUpdate)
                   ?(extra_labels = [])
                   ?(secret_keys = [])
                   ?(config_hash = "")
                   ~shape ~replicas ~cpu ~memory ~ns ~name ~image () =
  let ports_section =
    if shape = Http_service then {|        ports:
        - containerPort: 8080
|} else ""
  in
  let probe_section =
    if shape = Http_service then {|        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
|} else ""
  in
  let strategy_type = match rollout_strategy with
    | Sun_cli_toml.Recreate      -> "Recreate"
    | Sun_cli_toml.RollingUpdate -> "RollingUpdate"
  in
  let extra_labels_section =
    if extra_labels = [] then ""
    else "\n" ^ render_extra_labels extra_labels
  in
  let secret_env_section = render_secret_key_refs ~name secret_keys in
  f {|---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: %s
  namespace: %s
spec:
  replicas: %d
  strategy:
    type: %s
  selector:
    matchLabels:
      app: %s
  template:
    metadata:
      labels:
        app: %s%s
      annotations:
        sun.dev/config-hash: "%s"
    spec:
      serviceAccountName: %s
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: %s
        image: %s
        imagePullPolicy: Always
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
%s%s        envFrom:
        - configMapRef:
            name: %s-env
        - secretRef:
            name: %s-secrets
        resources:
          requests:
            cpu: %s
            memory: %s
          limits:
            cpu: %s
            memory: %s
%s|} name ns replicas strategy_type name name extra_labels_section config_hash name name image ports_section secret_env_section name name cpu memory cpu memory probe_section

(* ── Argo Rollouts helpers ────────────────────────────────────────────────── *)

(* Render a single canary step as a YAML list item with 10-space indent. *)
let render_canary_step = function
  | Sun_cli_toml.Weight n ->
    f "          - setWeight: %d" n
  | Sun_cli_toml.Pause None ->
    "          - pause: {}"
  | Sun_cli_toml.Pause (Some d) ->
    f "          - pause: {duration: %d}" d

(* Render the Argo Rollout strategy block for canary. *)
let render_canary_strategy steps =
  let step_lines = String.concat "\n" (List.map render_canary_step steps) in
  f {|      canary:
        steps:
%s|} step_lines

(* Render the Argo Rollout strategy block for blue-green. *)
let render_blue_green_strategy name =
  f {|      blueGreen:
        activeService: %s-active
        previewService: %s-preview
        autoPromotionEnabled: false|} name name

(** [rollout_doc] renders an Argo Rollout resource instead of a Deployment.
    The pod template is the same as a Deployment; only the top-level kind,
    apiVersion, and strategy section differ.  [progressive_delivery] must be
    [Some _] — callers in [render_spec] only invoke this when it is set. *)
let rollout_doc ?(extra_labels = []) ?(secret_keys = []) ?(config_hash = "") ~shape ~replicas ~cpu ~memory ~ns ~name ~image ~pd () =
  let ports_section =
    if shape = Http_service then {|        ports:
        - containerPort: 8080
|} else ""
  in
  let probe_section =
    if shape = Http_service then {|        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
|} else ""
  in
  let extra_labels_section =
    if extra_labels = [] then ""
    else "\n" ^ render_extra_labels extra_labels
  in
  let secret_env_section = render_secret_key_refs ~name secret_keys in
  let strategy_block = match pd with
    | Sun_cli_toml.Canary { steps } -> render_canary_strategy steps
    | Sun_cli_toml.Blue_green       -> render_blue_green_strategy name
  in
  f {|---
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: %s
  namespace: %s
spec:
  replicas: %d
  selector:
    matchLabels:
      app: %s
  template:
    metadata:
      labels:
        app: %s%s
      annotations:
        sun.dev/config-hash: "%s"
    spec:
      serviceAccountName: %s
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: %s
        image: %s
        imagePullPolicy: Always
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
%s%s        envFrom:
        - configMapRef:
            name: %s-env
        - secretRef:
            name: %s-secrets
        resources:
          requests:
            cpu: %s
            memory: %s
          limits:
            cpu: %s
            memory: %s
%s
  strategy:
%s|} name ns replicas name name extra_labels_section config_hash name name image ports_section secret_env_section name name cpu memory cpu memory probe_section strategy_block

(** Two ClusterIP Services required by the blue-green strategy:
    [<name>-active] receives live traffic; [<name>-preview] receives canary traffic.
    Both select pods with the [app: <name>] label — Argo manages the selector patch. *)
let blue_green_service_docs ~ns ~name =
  let make_svc svc_name =
    f {|---
apiVersion: v1
kind: Service
metadata:
  name: %s
  namespace: %s
spec:
  type: ClusterIP
  selector:
    app: %s
  ports:
  - port: 80
    targetPort: 8080|} svc_name ns name
  in
  make_svc (name ^ "-active") ^ "\n" ^ make_svc (name ^ "-preview")

(* ── Standard Service ────────────────────────────────────────────────────── *)

let service_doc ~ns ~name =
  f {|---
apiVersion: v1
kind: Service
metadata:
  name: %s
  namespace: %s
spec:
  type: ClusterIP
  selector:
    app: %s
  ports:
  - port: 80
    targetPort: 8080|} name ns name

let ingress_doc ?(ingress_host = "") ?(ingress_path = "/") ~ns ~name () =
  (* host line is optional — omit to match all hostnames. *)
  let host_line =
    if ingress_host = "" then ""
    else f "    host: %s\n" ingress_host
  in
  f {|---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: %s
  namespace: %s
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  rules:
  - %shttp:
      paths:
      - path: %s
        pathType: Prefix
        backend:
          service:
            name: %s
            port:
              number: 80|} name ns host_line ingress_path name

let network_policy_doc ~ns ~name =
  f {|---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: %s-netpol
  namespace: %s
spec:
  podSelector:
    matchLabels:
      app: %s
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
    - podSelector: {}
  egress:
  - ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: redpanda
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: postgresql
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring|} name ns name

let cronjob_doc ?(secret_keys = []) ~ns ~name ~image ~schedule () =
  let secret_env_section = render_secret_key_refs ~name secret_keys in
  f {|---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: %s
  namespace: %s
spec:
  schedule: "%s"
  jobTemplate:
    spec:
      backoffLimit: 3
      template:
        metadata:
          labels:
            app: %s
        spec:
          serviceAccountName: %s
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            runAsGroup: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
          - name: %s
            image: %s
            imagePullPolicy: Always
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
%s
            envFrom:
            - configMapRef:
                name: %s-env
            - secretRef:
                name: %s-secrets
            resources:
              requests:
                cpu: 100m
                memory: 128Mi
              limits:
                cpu: 250m
                memory: 256Mi|} name ns schedule name name name image secret_env_section name name

let render ?(toml = Sun_cli_toml.empty) svc ~ns ~name ~image =
  let replicas         = Option.value toml.replicas ~default:1 in
  let cpu              =
    match toml.cpu with
    | Some cpu -> Sun_cli_toml.cpu_quantity_to_string cpu
    | None -> "100m"
  in
  let memory           =
    match toml.memory with
    | Some memory -> Sun_cli_toml.memory_quantity_to_string memory
    | None -> "128Mi"
  in
  let rollout_strategy = Option.value toml.rollout_strategy
                           ~default:Sun_cli_toml.RollingUpdate in
  let progressive_delivery = toml.progressive_delivery in
  let extra_labels     = toml.extra_labels in
  let ingress_host     =
    match toml.ingress_host with
    | Some host -> Sun_cli_toml.hostname_to_string host
    | None -> ""
  in
  let ingress_path     =
    match toml.ingress_path with
    | Some path -> Sun_cli_toml.ingress_path_to_string path
    | None -> "/"
  in
  let config_hash      = config_hash toml.env_config in
  let ns_yaml = namespace_doc ~ns in
  let workload_yaml =
    let extra_secrets = List.map (fun k -> (k, "")) toml.Sun_cli_toml.secret_keys in
    let common = [
      service_account_doc ~ns ~name;
      configmap_doc ~extra_env:toml.env_config ~ns ~name ();
      secret_doc ~extra_secrets ~ns ~name ();
      network_policy_doc ~ns ~name;
    ] in
    let resources = match svc.primitive, progressive_delivery with
      | (Svc | Worker), Some pd ->
        let shape = if svc.primitive = Svc then Http_service else Background_worker in
        let rollout = rollout_doc ~extra_labels ~secret_keys:toml.Sun_cli_toml.secret_keys ~config_hash ~shape ~replicas ~cpu ~memory ~ns ~name ~image ~pd () in
        (match pd with
         | Sun_cli_toml.Blue_green ->
           [ rollout
           ; blue_green_service_docs ~ns ~name
           ; (if shape = Http_service then ingress_doc ~ingress_host ~ingress_path ~ns ~name:(name ^ "-active") () else "")
           ]
           |> List.filter (fun s -> s <> "")
         | Sun_cli_toml.Canary _ ->
           let svc_doc = if shape = Http_service then [service_doc ~ns ~name] else [] in
           let ingr    = if shape = Http_service then [ingress_doc ~ingress_host ~ingress_path ~ns ~name ()] else [] in
           [ rollout ] @ svc_doc @ ingr)
      | Svc, None ->
        [ deployment_doc ~rollout_strategy ~extra_labels ~config_hash
            ~shape:Http_service ~replicas ~cpu ~memory ~ns ~name ~image ()
        ; service_doc ~ns ~name
        ; ingress_doc ~ingress_host ~ingress_path ~ns ~name () ]
      | Worker, None ->
        [ deployment_doc ~rollout_strategy ~extra_labels ~config_hash
            ~shape:Background_worker ~replicas ~cpu ~memory ~ns ~name ~image () ]
      | Fn, _ ->
        let schedule = extract_schedule ~dir:svc.dir ~name:svc.name in
        [ cronjob_doc ~ns ~name ~image ~schedule () ]
    in
    String.concat "\n" (common @ resources)
  in
  (ns_yaml, workload_yaml)
