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

(* ── YAML templates ─────────────────────────────────────────────────────── *)

let default_cluster_env = [
  "KAFKA_BROKERS",       "redpanda.redpanda.svc.cluster.local:9093";
  "SCHEMA_REGISTRY_URL", "http://redpanda.redpanda.svc.cluster.local:8081";
  "REDPANDA_ADMIN_URL",  "http://redpanda.redpanda.svc.cluster.local:9644";
  "LOKI_URL",            "http://loki.monitoring.svc.cluster.local:3100";
  "PUSHGATEWAY_URL",     "http://prometheus-prometheus-pushgateway.monitoring.svc.cluster.local:9091";
]

(* Credentials that must never appear in ConfigMap — emitted as a Secret. *)
let default_secrets = [
  "POSTGRES_URL", "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev";
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

let namespace_doc ns =
  f {|---
apiVersion: v1
kind: Namespace
metadata:
  name: %s|} ns

let service_account_doc ns name =
  f {|---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: %s
  namespace: %s|} name ns

let configmap_doc ?(extra_env = []) ns name =
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
let secret_doc ?(extra_secrets = []) ?(redact = false) ns name =
  let secrets = default_secrets @ extra_secrets in
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
let external_secret_doc ~store_ref ~store_kind ~key_prefix ~refresh_interval ~secret_keys ns name =
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

let render_secret_key_refs secret_keys =
  match secret_keys with
  | [] -> ""
  | keys ->
    "\n        env:\n" ^
    String.concat "\n" (List.map (fun key ->
      f {|        - name: %s
          valueFrom:
            secretKeyRef:
              name: %s
              key: %s|} key runtime_secret_name key
    ) keys)

let render_extra_labels labels =
  (* Renders extra_labels as additional pod-template label lines (4-space indent). *)
  String.concat "\n" (List.map (fun (k, v) -> f "        %s: \"%s\"" k v) labels)

let deployment_doc ?(rollout_strategy = Sun_cli_toml.RollingUpdate)
                   ?(extra_labels = [])
                   ?(secret_keys = [])
                   ?(config_hash = "")
                   ~ports ~probes ~replicas ~cpu ~memory ns name image =
  let ports_section =
    if ports then {|        ports:
        - containerPort: 8080
|} else ""
  in
  let probe_section =
    if probes then {|        livenessProbe:
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
  let secret_env_section = render_secret_key_refs secret_keys in
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
let rollout_doc ?(extra_labels = []) ?(secret_keys = []) ?(config_hash = "") ~ports ~probes ~replicas ~cpu ~memory ns name image pd =
  let ports_section =
    if ports then {|        ports:
        - containerPort: 8080
|} else ""
  in
  let probe_section =
    if probes then {|        livenessProbe:
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
  let secret_env_section = render_secret_key_refs secret_keys in
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
            name: %s
        resources:
          requests:
            cpu: %s
            memory: %s
          limits:
            cpu: %s
            memory: %s
%s
  strategy:
%s|} name ns replicas name name extra_labels_section config_hash name name image ports_section secret_env_section name runtime_secret_name cpu memory cpu memory probe_section strategy_block

(** Two ClusterIP Services required by the blue-green strategy:
    [<name>-active] receives live traffic; [<name>-preview] receives canary traffic.
    Both select pods with the [app: <name>] label — Argo manages the selector patch. *)
let blue_green_service_docs ns name =
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

let service_doc ns name =
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

let ingress_doc ?(ingress_host = "") ?(ingress_path = "/") ns name =
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

let network_policy_doc ns name =
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

let cronjob_doc ?(secret_keys = []) ns name image schedule =
  let secret_env_section = render_secret_key_refs secret_keys in
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
                memory: 256Mi|} name ns schedule name name image secret_env_section name name

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
