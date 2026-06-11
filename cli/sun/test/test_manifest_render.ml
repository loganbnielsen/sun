(* Regression tests for Sun_cli_deployment_plan.render_spec.
   Constructs service_spec values directly (no filesystem required) and checks
   that the rendered YAML contains the expected resource names, image
   references, namespaces, and primitive-specific resources. *)

let check_string = Alcotest.(check string)
let check_bool   = Alcotest.(check bool)

(* ── helpers ─────────────────────────────────────────────────────────────── *)

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else begin
    let found = ref false in
    for i = 0 to hl - nl do
      if not !found && String.sub haystack i nl = needle then found := true
    done;
    !found
  end

let assert_contains label haystack needle =
  check_bool (Printf.sprintf "%s: contains %S" label needle) true
    (contains haystack needle)

let assert_absent label haystack needle =
  check_bool (Printf.sprintf "%s: absent %S" label needle) false
    (contains haystack needle)

(* Extract the YAML document block that contains [kind_marker] (e.g. "kind: ConfigMap").
   Splits the full YAML on "---" separators and returns the first block that
   contains the marker, or the empty string if none is found. *)
let extract_kind_block yaml kind_marker =
  (* Split on "\n---" or start-of-string "---" boundaries *)
  let sep = "\n---" in
  let sl  = String.length sep in
  let yl  = String.length yaml in
  let blocks = ref [] in
  let start  = ref 0 in
  for i = 0 to yl - sl do
    if String.sub yaml i sl = sep then begin
      blocks := String.sub yaml !start (i - !start) :: !blocks;
      start := i + 1   (* keep the "---" at the start of the next block *)
    end
  done;
  blocks := String.sub yaml !start (yl - !start) :: !blocks;
  let result = ref "" in
  List.iter (fun b ->
    if !result = "" && contains b kind_marker then result := b
  ) (List.rev !blocks);
  !result

(* ── fixtures ────────────────────────────────────────────────────────────── *)

let svc_spec : Sun_cli_deployment_plan.service_spec = {
  domain                = "payments";
  source_name           = "charge_svc";
  k8s_name              = "charge-svc";
  namespace             = "myapp-payments";
  primitive             = Sun_cli_deployment_plan.Svc;
  source_dir            = "app/payments/charge_svc";
  image                 = "sun-registry:5000/myapp/charge-svc:abc123";
  config                = [ "APP_ENV", "staging" ];
  secrets               = [];
  schedule              = None;
  replicas              = 2;
  cpu                   = "200m";
  memory                = "256Mi";
  rollout_strategy      = None;
  ingress_host          = None;
  ingress_path          = None;
  extra_labels          = [];
  progressive_delivery  = None;
}

let worker_spec : Sun_cli_deployment_plan.service_spec = {
  domain                = "comms";
  source_name           = "notify_worker";
  k8s_name              = "notify-worker";
  namespace             = "myapp-comms";
  primitive             = Sun_cli_deployment_plan.Worker;
  source_dir            = "app/comms/notify_worker";
  image                 = "sun-registry:5000/myapp/notify-worker:abc123";
  config                = [];
  secrets               = [];
  schedule              = None;
  replicas              = 1;
  cpu                   = "100m";
  memory                = "128Mi";
  rollout_strategy      = None;
  ingress_host          = None;
  ingress_path          = None;
  extra_labels          = [];
  progressive_delivery  = None;
}

let fn_spec : Sun_cli_deployment_plan.service_spec = {
  domain                = "billing";
  source_name           = "invoice_fn";
  k8s_name              = "invoice-fn";
  namespace             = "myapp-billing";
  primitive             = Sun_cli_deployment_plan.Fn;
  source_dir            = "app/billing/invoice_fn";
  image                 = "sun-registry:5000/myapp/invoice-fn:abc123";
  config                = [];
  secrets               = [];
  schedule              = Some "0 9 * * 1";
  replicas              = 1;
  cpu                   = "100m";
  memory                = "128Mi";
  rollout_strategy      = None;
  ingress_host          = None;
  ingress_path          = None;
  extra_labels          = [];
  progressive_delivery  = None;
}

(* ── Svc tests ───────────────────────────────────────────────────────────── *)

let test_svc_namespace () =
  let (ns_yaml, _workload) = Sun_cli_deployment_plan.render_spec svc_spec in
  assert_contains "svc ns_yaml" ns_yaml "name: myapp-payments"

let test_svc_deployment_name () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec svc_spec in
  assert_contains "svc deployment name" workload "name: charge-svc"

let test_svc_image () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec svc_spec in
  assert_contains "svc image" workload "sun-registry:5000/myapp/charge-svc:abc123"

let test_svc_has_service_resource () =
  (* "kind: Service\n" matches the Service resource, not ServiceAccount *)
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec svc_spec in
  assert_contains "svc Service resource" workload "kind: Service\n"

let test_svc_has_ingress () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec svc_spec in
  assert_contains "svc Ingress resource" workload "kind: Ingress"

let test_svc_has_ports () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec svc_spec in
  assert_contains "svc containerPort" workload "containerPort: 8080"

let test_svc_replicas () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec svc_spec in
  assert_contains "svc replicas=2" workload "replicas: 2"

let test_svc_extra_config () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec svc_spec in
  assert_contains "svc extra configmap key" workload {|APP_ENV: "staging"|}

let test_svc_default_postgres_url () =
  (* POSTGRES_URL must be in the Secret, not the ConfigMap *)
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec svc_spec in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "svc default postgres url in secret" secret_block
    {|POSTGRES_URL: "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev"|}

let test_postgres_url_not_in_configmap () =
  (* POSTGRES_URL must never appear in the ConfigMap — it contains an embedded password *)
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec svc_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_absent "POSTGRES_URL absent from ConfigMap" cm_block "POSTGRES_URL"

let test_postgres_url_in_secret () =
  (* A Secret resource must be emitted and must contain POSTGRES_URL in stringData *)
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec svc_spec in
  assert_contains "Secret resource present" workload "kind: Secret";
  assert_contains "stringData section" workload "stringData:";
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "POSTGRES_URL in stringData" secret_block
    {|POSTGRES_URL: "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev"|}

let test_svc_default_redpanda_admin_url () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec svc_spec in
  assert_contains "svc default redpanda admin url" workload
    {|REDPANDA_ADMIN_URL: "http://redpanda.redpanda.svc.cluster.local:9644"|}

let test_svc_secret_refs_without_values () =
  let spec = {
    svc_spec with
    secrets = [ "DATABASE_URL", "postgres://secret"; "API_TOKEN", "token-value" ];
  } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  assert_contains "database secret ref" workload "key: DATABASE_URL";
  assert_contains "api token secret ref" workload "key: API_TOKEN";
  assert_absent "database value absent" workload "postgres://secret";
  assert_absent "token value absent" workload "token-value";
  assert_contains "shared secret name" workload "name: sun-secrets"

let test_svc_namespace_in_workload () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec svc_spec in
  assert_contains "svc workload namespace" workload "namespace: myapp-payments"

(* ── AUDIT-016: user-defined secret_keys emitted as Secret resource ───────── *)

(* When secrets = [("STRIPE_KEY", "")] the rendered workload must include a
   Secret resource (kind: Secret) that carries STRIPE_KEY in its stringData
   section.  The value is empty — operators fill it in at apply time. *)
let test_user_secret_key_in_secret_resource () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "STRIPE_KEY present in Secret resource" secret_block "STRIPE_KEY:"

(* The key reference in the Deployment env block must also be present. *)
let test_user_secret_key_ref_in_deployment () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  assert_contains "STRIPE_KEY secretKeyRef" workload "key: STRIPE_KEY"

(* Multiple user-defined secret keys must all appear in the Secret resource. *)
let test_multiple_user_secret_keys_in_secret_resource () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", ""; "SENDGRID_API_KEY", "" ] } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "STRIPE_KEY in Secret"       secret_block "STRIPE_KEY:";
  assert_contains "SENDGRID_API_KEY in Secret" secret_block "SENDGRID_API_KEY:"

(* The default POSTGRES_URL must still be present alongside user secrets. *)
let test_default_secrets_preserved_with_user_secrets () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "POSTGRES_URL still in Secret" secret_block "POSTGRES_URL:";
  assert_contains "STRIPE_KEY also in Secret"    secret_block "STRIPE_KEY:"

(* Worker with secret_keys also emits Secret resource with those keys. *)
let test_worker_user_secret_key_in_secret_resource () =
  let spec = { worker_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "worker STRIPE_KEY in Secret" secret_block "STRIPE_KEY:"

(* Fn/CronJob with secret_keys also emits Secret resource with those keys. *)
let test_fn_user_secret_key_in_secret_resource () =
  let spec = { fn_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  let secret_block = extract_kind_block workload "kind: Secret" in
  assert_contains "fn STRIPE_KEY in Secret" secret_block "STRIPE_KEY:"

(* image override: dry-run uses push_image *)
let test_svc_image_override () =
  let push_image = "localhost:5000/myapp/charge-svc:abc123" in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec ~image:push_image svc_spec in
  assert_contains "svc push image in dry-run" workload "localhost:5000/myapp/charge-svc:abc123";
  assert_absent "svc cluster image absent" workload "sun-registry:5000/myapp/charge-svc:abc123"

(* ── Worker tests ────────────────────────────────────────────────────────── *)

let test_worker_namespace () =
  let (ns_yaml, _) = Sun_cli_deployment_plan.render_spec worker_spec in
  assert_contains "worker ns" ns_yaml "name: myapp-comms"

let test_worker_image () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec worker_spec in
  assert_contains "worker image" workload "sun-registry:5000/myapp/notify-worker:abc123"

let test_worker_no_service_resource () =
  (* Workers don't expose HTTP — no Service or Ingress resource.
     Check for "kind: Service\n" to avoid matching "kind: ServiceAccount". *)
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec worker_spec in
  assert_absent "worker no Service resource" workload "kind: Service\n";
  assert_absent "worker no Ingress" workload "kind: Ingress"

let test_worker_no_ports () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec worker_spec in
  assert_absent "worker no containerPort" workload "containerPort:"

let test_worker_has_deployment () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec worker_spec in
  assert_contains "worker Deployment" workload "kind: Deployment"

(* ── Fn tests ────────────────────────────────────────────────────────────── *)

let test_fn_namespace () =
  let (ns_yaml, _) = Sun_cli_deployment_plan.render_spec fn_spec in
  assert_contains "fn ns" ns_yaml "name: myapp-billing"

let test_fn_image () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec fn_spec in
  assert_contains "fn image" workload "sun-registry:5000/myapp/invoice-fn:abc123"

let test_fn_cronjob () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec fn_spec in
  assert_contains "fn CronJob kind" workload "kind: CronJob"

let test_fn_schedule () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec fn_spec in
  assert_contains "fn schedule" workload {|schedule: "0 9 * * 1"|}

let test_fn_no_deployment () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec fn_spec in
  assert_absent "fn no Deployment" workload "kind: Deployment"

let test_fn_default_schedule () =
  (* When schedule=None the default cron expression is used *)
  let spec = { fn_spec with schedule = None } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  assert_contains "fn default schedule" workload {|schedule: "0 * * * *"|}

(* ── resource stability: render_spec and render produce the same YAML ───── *)

(* Ensure that render_spec generates the same output as the legacy render path
   for a plain svc with no toml overrides (replicas=1, cpu=100m, memory=128Mi). *)
let test_svc_render_spec_matches_render () =
  let plain_spec : Sun_cli_deployment_plan.service_spec = {
    domain                = "payments";
    source_name           = "charge_svc";
    k8s_name              = "charge-svc";
    namespace             = "myapp-payments";
    primitive             = Sun_cli_deployment_plan.Svc;
    source_dir            = "app/payments/charge_svc";
    image                 = "sun-registry:5000/myapp/charge-svc:abc123";
    config                = [];
    secrets               = [];
    schedule              = None;
    replicas              = 1;
    cpu                   = "100m";
    memory                = "128Mi";
    rollout_strategy      = None;
    ingress_host          = None;
    ingress_path          = None;
    extra_labels          = [];
    progressive_delivery  = None;
  } in
  let svc : Sun_cli_manifest.service = {
    domain = "payments";
    name   = "charge_svc";
    prim   = Sun_cli_manifest.Svc;
    dir    = "app/payments/charge_svc";
  } in
  let (ns1, w1) = Sun_cli_deployment_plan.render_spec plain_spec in
  let (ns2, w2) = Sun_cli_manifest.render svc
    ~ns:"myapp-payments" ~name:"charge-svc"
    ~image:"sun-registry:5000/myapp/charge-svc:abc123" in
  check_string "render_spec ns == render ns"       ns1 ns2;
  check_string "render_spec workload == render workload" w1 w2

(* ── Escape-hatch tests ──────────────────────────────────────────────────── *)

let test_rollout_recreate () =
  (* rollout_strategy = Recreate must produce "type: Recreate" in the Deployment spec *)
  let spec = { svc_spec with rollout_strategy = Some Sun_cli_toml.Recreate } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  assert_contains "recreate strategy" workload "type: Recreate";
  assert_absent   "no RollingUpdate"  workload "type: RollingUpdate"

let test_rollout_rolling_update () =
  (* rollout_strategy = RollingUpdate (explicit) must produce "type: RollingUpdate" *)
  let spec = { svc_spec with rollout_strategy = Some Sun_cli_toml.RollingUpdate } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  assert_contains "rolling strategy" workload "type: RollingUpdate";
  assert_absent   "no Recreate"      workload "type: Recreate"

let test_rollout_default_is_rolling_update () =
  (* Default (None) must also produce RollingUpdate *)
  let spec = { svc_spec with rollout_strategy = None } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  assert_contains "default is RollingUpdate" workload "type: RollingUpdate"

let test_progressive_default_is_deployment () =
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec svc_spec in
  assert_contains "default Deployment" workload "kind: Deployment";
  assert_absent   "default no Rollout"  workload "kind: Rollout"

let test_progressive_canary_rollout () =
  let spec = {
    svc_spec with
    progressive_delivery =
      Some (Sun_cli_toml.Canary {
        steps = [ Sun_cli_toml.Weight 10; Sun_cli_toml.Weight 40; Sun_cli_toml.Weight 100 ];
      });
  } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  assert_contains "rollout api" workload "apiVersion: argoproj.io/v1alpha1";
  assert_contains "rollout kind" workload "kind: Rollout";
  assert_contains "canary block" workload "canary:";
  assert_contains "weight 10" workload "setWeight: 10";
  assert_contains "weight 40" workload "setWeight: 40";
  assert_contains "weight 100" workload "setWeight: 100";
  assert_contains "svc port preserved" workload "containerPort: 8080";
  assert_contains "svc probes preserved" workload "readinessProbe:";
  assert_absent   "no Deployment" workload "kind: Deployment"

let test_progressive_canary_worker_no_service () =
  let spec = {
    worker_spec with
    progressive_delivery =
      Some (Sun_cli_toml.Canary { steps = [ Sun_cli_toml.Weight 50 ] });
  } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  assert_contains "worker rollout kind" workload "kind: Rollout";
  assert_contains "worker canary step" workload "setWeight: 50";
  assert_absent "worker no ingress" workload "kind: Ingress";
  assert_absent "worker no service port" workload "port: 80";
  assert_absent "worker no port" workload "containerPort: 8080"

let test_progressive_blue_green_rollout () =
  let spec = {
    svc_spec with
    progressive_delivery = Some Sun_cli_toml.Blue_green;
  } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  assert_contains "rollout kind" workload "kind: Rollout";
  assert_contains "blueGreen block" workload "blueGreen:";
  assert_contains "active service strategy" workload "activeService: charge-svc-active";
  assert_contains "preview service strategy" workload "previewService: charge-svc-preview";
  assert_contains "manual promotion" workload "autoPromotionEnabled: false";
  assert_contains "active service manifest" workload "name: charge-svc-active";
  assert_contains "preview service manifest" workload "name: charge-svc-preview";
  assert_contains "ingress points at active" workload "name: charge-svc-active";
  assert_absent   "no Deployment" workload "kind: Deployment"

(* ── AUDIT-019: Argo Rollout uses sun-secrets, not <name>-secrets ─────────── *)

(* Canary Rollout with secrets must reference sun-secrets (not charge-svc-secrets)
   in the secretKeyRef block, and must NOT contain any per-service secret name. *)
let test_rollout_canary_secrets_use_sun_secrets () =
  let spec = {
    svc_spec with
    progressive_delivery =
      Some (Sun_cli_toml.Canary {
        steps = [ Sun_cli_toml.Weight 50; Sun_cli_toml.Weight 100 ];
      });
    secrets = [ "STRIPE_KEY", ""; "DATABASE_URL", "" ];
  } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  let rollout_block = extract_kind_block workload "kind: Rollout" in
  assert_contains "rollout uses sun-secrets ref"       rollout_block "name: sun-secrets";
  assert_contains "rollout has STRIPE_KEY ref"         rollout_block "key: STRIPE_KEY";
  assert_contains "rollout has DATABASE_URL ref"       rollout_block "key: DATABASE_URL";
  assert_absent   "no per-service secret name"         rollout_block "name: charge-svc-secrets"

(* Blue-green Rollout with secrets must also reference sun-secrets. *)
let test_rollout_blue_green_secrets_use_sun_secrets () =
  let spec = {
    svc_spec with
    progressive_delivery = Some Sun_cli_toml.Blue_green;
    secrets = [ "API_TOKEN", "" ];
  } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  let rollout_block = extract_kind_block workload "kind: Rollout" in
  assert_contains "blue-green rollout uses sun-secrets" rollout_block "name: sun-secrets";
  assert_contains "blue-green rollout has API_TOKEN ref" rollout_block "key: API_TOKEN";
  assert_absent   "no per-service secret name"          rollout_block "name: charge-svc-secrets"

let test_ingress_host_override () =
  (* ingress_host override must appear in the Ingress rule *)
  let spec = { svc_spec with ingress_host = Some "payments.example.com" } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  assert_contains "ingress host" workload "host: payments.example.com"

let test_ingress_path_override () =
  (* ingress_path override must appear in the path field *)
  let spec = { svc_spec with ingress_path = Some "/api/v2" } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  assert_contains "ingress path" workload "path: /api/v2"

let test_ingress_default_path () =
  (* Default path is "/" *)
  let spec = { svc_spec with ingress_path = None } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  assert_contains "default path" workload "path: /"

let test_extra_labels_appear_in_pod_template () =
  (* extra_labels must appear in the pod template metadata.labels block *)
  let spec = { svc_spec with extra_labels = [ "team", "platform"; "tier", "backend" ] } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  assert_contains "extra label team"  workload {|team: "platform"|};
  assert_contains "extra label tier"  workload {|tier: "backend"|}

let test_extra_labels_empty_by_default () =
  (* No extra labels → no spurious keys in pod template *)
  let spec = { svc_spec with extra_labels = [] } in
  let (_ns, workload) = Sun_cli_deployment_plan.render_spec spec in
  assert_absent "no team label" workload {|team:|}

let test_toml_invalid_rollout_strategy () =
  (* load should raise Failure for unknown rollout_strategy values *)
  let path = Filename.temp_file "sun-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc "[infra.deploy]\nrollout_strategy = \"Blue/Green\"\n";
  close_out oc;
  let raised =
    try let _ = Sun_cli_toml.load path in false
    with Failure _ -> true
  in
  Sys.remove path;
  check_bool "invalid rollout_strategy raises" true raised

let test_toml_reserved_label_key () =
  (* extra_labels keys starting with "sun.dev/" must be rejected *)
  let path = Filename.temp_file "sun-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc {|[infra.labels]
extra_labels = { "sun.dev/owner" = "platform" }
|};
  close_out oc;
  let raised =
    try let _ = Sun_cli_toml.load path in false
    with Failure _ -> true
  in
  Sys.remove path;
  check_bool "reserved label key raises" true raised

let test_toml_valid_rollout_recreate () =
  (* Parsing Recreate from sun.toml should populate rollout_strategy correctly *)
  let path = Filename.temp_file "sun-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc "[infra.deploy]\nrollout_strategy = \"Recreate\"\n";
  close_out oc;
  let toml = Sun_cli_toml.load path in
  Sys.remove path;
  check_bool "rollout_strategy is Recreate"
    true (toml.Sun_cli_toml.rollout_strategy = Some Sun_cli_toml.Recreate)

let test_toml_valid_ingress_overrides () =
  (* Parsing ingress_host and ingress_path from sun.toml *)
  let path = Filename.temp_file "sun-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc {|[infra.deploy]
ingress_host = "api.example.com"
ingress_path = "/v1"
|};
  close_out oc;
  let toml = Sun_cli_toml.load path in
  Sys.remove path;
  check_bool "ingress_host parsed"
    true (toml.Sun_cli_toml.ingress_host = Some "api.example.com");
  check_bool "ingress_path parsed"
    true (toml.Sun_cli_toml.ingress_path = Some "/v1")

let test_toml_secret_keys () =
  let path = Filename.temp_file "sun-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc {|[infra.env]
secrets = ["DATABASE_URL", "API_TOKEN"]
|};
  close_out oc;
  let toml = Sun_cli_toml.load path in
  Sys.remove path;
  check_bool "secret keys parsed"
    true (toml.Sun_cli_toml.secret_keys = [ "DATABASE_URL"; "API_TOKEN" ])

let test_toml_valid_canary_rollout () =
  let path = Filename.temp_file "sun-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc {|[infra.rollout]
strategy = "canary"
steps = [10, 40, 100]
|};
  close_out oc;
  let toml = Sun_cli_toml.load path in
  Sys.remove path;
  match toml.Sun_cli_toml.progressive_delivery with
  | Some (Sun_cli_toml.Canary {
      steps = [
        Sun_cli_toml.Weight 10;
        Sun_cli_toml.Weight 40;
        Sun_cli_toml.Weight 100;
      ];
    }) -> ()
  | _ -> Alcotest.fail "expected canary progressive_delivery from [infra.rollout]"

let test_toml_valid_blue_green_rollout () =
  let path = Filename.temp_file "sun-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc {|[infra.rollout]
strategy = "blue-green"
|};
  close_out oc;
  let toml = Sun_cli_toml.load path in
  Sys.remove path;
  check_bool "blue-green parsed"
    true (toml.Sun_cli_toml.progressive_delivery = Some Sun_cli_toml.Blue_green)

let test_toml_invalid_progressive_strategy () =
  let path = Filename.temp_file "sun-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc {|[infra.rollout]
strategy = "rolling"
|};
  close_out oc;
  let raised =
    try let _ = Sun_cli_toml.load path in false
    with Failure _ -> true
  in
  Sys.remove path;
  check_bool "invalid progressive strategy raises" true raised

let test_toml_canary_requires_steps () =
  let path = Filename.temp_file "sun-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc {|[infra.rollout]
strategy = "canary"
|};
  close_out oc;
  let raised =
    try let _ = Sun_cli_toml.load path in false
    with Failure _ -> true
  in
  Sys.remove path;
  check_bool "canary without steps raises" true raised

let test_toml_canary_rejects_bad_weight () =
  let path = Filename.temp_file "sun-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc {|[infra.rollout]
strategy = "canary"
steps = [10, 120]
|};
  close_out oc;
  let raised =
    try let _ = Sun_cli_toml.load path in false
    with Failure _ -> true
  in
  Sys.remove path;
  check_bool "invalid canary weight raises" true raised

let () =
  Alcotest.run "manifest_render"
    [ "svc", [
        Alcotest.test_case "namespace yaml"         `Quick test_svc_namespace
      ; Alcotest.test_case "deployment name"        `Quick test_svc_deployment_name
      ; Alcotest.test_case "image"                  `Quick test_svc_image
      ; Alcotest.test_case "has Service resource"   `Quick test_svc_has_service_resource
      ; Alcotest.test_case "has Ingress"            `Quick test_svc_has_ingress
      ; Alcotest.test_case "has containerPort"      `Quick test_svc_has_ports
      ; Alcotest.test_case "replicas from spec"     `Quick test_svc_replicas
      ; Alcotest.test_case "extra config in map"    `Quick test_svc_extra_config
      ; Alcotest.test_case "default postgres url"   `Quick test_svc_default_postgres_url
      ; Alcotest.test_case "POSTGRES_URL not in ConfigMap" `Quick test_postgres_url_not_in_configmap
      ; Alcotest.test_case "POSTGRES_URL in Secret"        `Quick test_postgres_url_in_secret
      ; Alcotest.test_case "default redpanda admin" `Quick test_svc_default_redpanda_admin_url
      ; Alcotest.test_case "secret refs no values"  `Quick test_svc_secret_refs_without_values
      ; Alcotest.test_case "namespace in workload"  `Quick test_svc_namespace_in_workload
      ; Alcotest.test_case "image override (up dry-run)" `Quick test_svc_image_override
      ; Alcotest.test_case "user secret key in Secret resource" `Quick test_user_secret_key_in_secret_resource
      ; Alcotest.test_case "user secret key ref in Deployment"  `Quick test_user_secret_key_ref_in_deployment
      ; Alcotest.test_case "multiple user secret keys in Secret" `Quick test_multiple_user_secret_keys_in_secret_resource
      ; Alcotest.test_case "default secrets preserved with user secrets" `Quick test_default_secrets_preserved_with_user_secrets
      ]
    ; "worker", [
        Alcotest.test_case "namespace yaml"         `Quick test_worker_namespace
      ; Alcotest.test_case "image"                  `Quick test_worker_image
      ; Alcotest.test_case "no Service/Ingress"     `Quick test_worker_no_service_resource
      ; Alcotest.test_case "no containerPort"       `Quick test_worker_no_ports
      ; Alcotest.test_case "has Deployment"         `Quick test_worker_has_deployment
      ; Alcotest.test_case "user secret key in Secret resource" `Quick test_worker_user_secret_key_in_secret_resource
      ]
    ; "fn", [
        Alcotest.test_case "namespace yaml"         `Quick test_fn_namespace
      ; Alcotest.test_case "image"                  `Quick test_fn_image
      ; Alcotest.test_case "kind CronJob"           `Quick test_fn_cronjob
      ; Alcotest.test_case "schedule from spec"     `Quick test_fn_schedule
      ; Alcotest.test_case "no Deployment"          `Quick test_fn_no_deployment
      ; Alcotest.test_case "default schedule"       `Quick test_fn_default_schedule
      ; Alcotest.test_case "user secret key in Secret resource" `Quick test_fn_user_secret_key_in_secret_resource
      ]
    ; "parity", [
        Alcotest.test_case "render_spec == render (plain svc)" `Quick test_svc_render_spec_matches_render
      ]
    ; "escape_hatches", [
        Alcotest.test_case "rollout Recreate"              `Quick test_rollout_recreate
      ; Alcotest.test_case "rollout RollingUpdate"         `Quick test_rollout_rolling_update
      ; Alcotest.test_case "rollout default=RollingUpdate" `Quick test_rollout_default_is_rolling_update
      ; Alcotest.test_case "progressive default Deployment" `Quick test_progressive_default_is_deployment
      ; Alcotest.test_case "progressive canary Rollout"    `Quick test_progressive_canary_rollout
      ; Alcotest.test_case "progressive worker canary"     `Quick test_progressive_canary_worker_no_service
      ; Alcotest.test_case "progressive blue-green Rollout" `Quick test_progressive_blue_green_rollout
      ; Alcotest.test_case "rollout canary secrets use sun-secrets"     `Quick test_rollout_canary_secrets_use_sun_secrets
      ; Alcotest.test_case "rollout blue-green secrets use sun-secrets" `Quick test_rollout_blue_green_secrets_use_sun_secrets
      ; Alcotest.test_case "ingress host override"         `Quick test_ingress_host_override
      ; Alcotest.test_case "ingress path override"         `Quick test_ingress_path_override
      ; Alcotest.test_case "ingress default path"          `Quick test_ingress_default_path
      ; Alcotest.test_case "extra_labels in pod template"  `Quick test_extra_labels_appear_in_pod_template
      ; Alcotest.test_case "extra_labels empty default"    `Quick test_extra_labels_empty_by_default
      ; Alcotest.test_case "invalid rollout_strategy"      `Quick test_toml_invalid_rollout_strategy
      ; Alcotest.test_case "reserved label key rejected"   `Quick test_toml_reserved_label_key
      ; Alcotest.test_case "valid Recreate from toml"      `Quick test_toml_valid_rollout_recreate
      ; Alcotest.test_case "valid ingress overrides toml"  `Quick test_toml_valid_ingress_overrides
      ; Alcotest.test_case "secret keys from toml"          `Quick test_toml_secret_keys
      ; Alcotest.test_case "valid canary rollout toml"     `Quick test_toml_valid_canary_rollout
      ; Alcotest.test_case "valid blue-green rollout toml" `Quick test_toml_valid_blue_green_rollout
      ; Alcotest.test_case "invalid progressive strategy"  `Quick test_toml_invalid_progressive_strategy
      ; Alcotest.test_case "canary requires steps"         `Quick test_toml_canary_requires_steps
      ; Alcotest.test_case "canary rejects bad weight"     `Quick test_toml_canary_rejects_bad_weight
      ]
    ]
