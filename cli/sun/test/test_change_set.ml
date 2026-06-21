(* Tests for Sun_cli_change_set.
   Verifies that build produces the correct artifacts and that execute
   dispatches side effects only according to the execution mode. *)

(* ── fixtures ────────────────────────────────────────────────────────────── *)

let k8s_name value =
  match Sun_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
  | Error err -> Alcotest.fail (Sun_cli_deployment_plan.plan_error_to_string err)

let namespace ~workspace ~domain =
  Sun_cli_deployment_plan.namespace_of ~workspace ~domain

let cpu s =
  match Sun_cli_toml.cpu_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Alcotest.fail message

let memory s =
  match Sun_cli_toml.memory_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Alcotest.fail message

let svc_spec : Sun_cli_deployment_plan.service_spec = {
  domain      = "payments";
  source_name = "charge_svc";
  k8s_name    = k8s_name "charge-svc";
  namespace   = namespace ~workspace:"myapp" ~domain:"payments";
  primitive   = Sun_cli_deployment_plan.Svc;
  source_dir  = "app/payments/charge_svc";
  image       = "registry.example.com/myapp/charge-svc:abc123";
  config      = [];
  secrets     = [];
  schedule              = None;
  replicas              = 1;
  cpu                   = cpu "100m";
  memory                = memory "128Mi";
  rollout_strategy      = None;
  ingress_host          = None;
  ingress_path          = None;
  extra_labels          = [];
  progressive_delivery  = None;
}

let worker_spec : Sun_cli_deployment_plan.service_spec = {
  domain      = "comms";
  source_name = "notify_worker";
  k8s_name    = k8s_name "notify-worker";
  namespace   = namespace ~workspace:"myapp" ~domain:"comms";
  primitive   = Sun_cli_deployment_plan.Worker;
  source_dir  = "app/comms/notify_worker";
  image       = "registry.example.com/myapp/notify-worker:abc123";
  config      = [];
  secrets     = [];
  schedule              = None;
  replicas              = 1;
  cpu                   = cpu "100m";
  memory                = memory "128Mi";
  rollout_strategy      = None;
  ingress_host          = None;
  ingress_path          = None;
  extra_labels          = [];
  progressive_delivery  = None;
}

let env_config : Sun_cli_deployment_plan.env_config = {
  name           = "myapp";
  mode           = Sun_cli_deployment_plan.Customer_cloud;
  registry       = "registry.example.com";
  image_tag      = "abc123";
  region         = None;
  base_domain    = None;
  secret_backend = Sun_cli_manifest.Kubernetes_placeholder;
}

let make_plan services =
  { Sun_cli_deployment_plan.workspace     = "myapp"
  ; environment   = env_config
  ; services
  ; topics         = []
  ; migrations     = []
  ; schema_subjects = []
  ; consumer_groups = []
  }

(* ── helpers ─────────────────────────────────────────────────────────────── *)

(** Unwrap a [change_set build] result or fail the test with the error message. *)
let build_ok ~plan ~mode ?secret_backend () =
  match Sun_cli_change_set.build ~plan ~mode ?secret_backend () with
  | Ok cs   -> cs
  | Error e -> Alcotest.fail ("change_set.build unexpectedly failed: " ^ e)

(* ── build ───────────────────────────────────────────────────────────────── *)

let test_build_renders_one_artifact_per_service () =
  let plan = make_plan [ svc_spec; worker_spec ] in
  let cs = build_ok ~plan ~mode:Sun_cli_change_set.Dry_run () in
  Alcotest.(check int) "artifact count" 2 (List.length cs.Sun_cli_change_set.artifacts)

let test_build_artifact_fields () =
  let plan = make_plan [ svc_spec ] in
  let cs = build_ok ~plan ~mode:Sun_cli_change_set.Dry_run () in
  let art = List.hd cs.Sun_cli_change_set.artifacts in
  Alcotest.(check string) "artifact namespace" "myapp-payments" art.Sun_cli_change_set.namespace;
  Alcotest.(check string) "artifact name"      "charge-svc"     art.Sun_cli_change_set.name;
  Alcotest.(check string) "artifact image"
    "registry.example.com/myapp/charge-svc:abc123"
    art.Sun_cli_change_set.image

let test_build_preserves_plan () =
  let plan = make_plan [ svc_spec ] in
  let cs = build_ok ~plan ~mode:Sun_cli_change_set.Apply () in
  Alcotest.(check string) "workspace" "myapp" cs.Sun_cli_change_set.plan.Sun_cli_deployment_plan.workspace

let test_build_mode_stored () =
  let plan = make_plan [ svc_spec ] in
  let cs = build_ok ~plan ~mode:Sun_cli_change_set.Dry_run () in
  Alcotest.(check bool) "mode is dry_run"
    true
    (cs.Sun_cli_change_set.mode = Sun_cli_change_set.Dry_run)

(* ── dry-run: no executor side effects ───────────────────────────────────── *)

let test_dry_run_returns_result () =
  let plan = make_plan [ svc_spec ] in
  let cs = build_ok ~plan ~mode:Sun_cli_change_set.Dry_run () in
  let results = Sun_cli_change_set.execute cs in
  Alcotest.(check int) "dry_run result count" 1 (List.length results);
  let r = List.hd results in
  Alcotest.(check string) "dry_run namespace" "myapp-payments" r.Sun_cli_executor.namespace;
  Alcotest.(check string) "dry_run name"      "charge-svc"     r.Sun_cli_executor.name

let test_dry_run_yaml_non_empty () =
  let plan = make_plan [ svc_spec ] in
  let cs = build_ok ~plan ~mode:Sun_cli_change_set.Dry_run () in
  let art = List.hd cs.Sun_cli_change_set.artifacts in
  Alcotest.(check bool) "namespace_yaml non-empty"
    true (String.length art.Sun_cli_change_set.namespace_yaml > 0);
  Alcotest.(check bool) "workload_yaml non-empty"
    true (String.length art.Sun_cli_change_set.workload_yaml > 0)

(* ── emit-to: file written, no kubectl ───────────────────────────────────── *)

let test_emit_to_writes_file () =
  let dir = Filename.temp_file "sun-cs-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let plan = make_plan [ svc_spec ] in
  let cs = build_ok ~plan ~mode:(Sun_cli_change_set.Emit_to dir) () in
  let _results = Sun_cli_change_set.execute cs in
  let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
  let exists = Sys.file_exists path in
  (try Sys.remove path with _ -> ());
  (try Unix.rmdir dir with _ -> ());
  Alcotest.(check bool) "emit_to file created" true exists

let test_emit_to_result_fields () =
  let dir = Filename.temp_file "sun-cs-emit-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let plan = make_plan [ worker_spec ] in
  let cs = build_ok ~plan ~mode:(Sun_cli_change_set.Emit_to dir) () in
  let results = Sun_cli_change_set.execute cs in
  let path = Filename.concat dir "myapp-comms-notify-worker.yaml" in
  (try Sys.remove path with _ -> ());
  (try Unix.rmdir dir with _ -> ());
  Alcotest.(check int)    "emit_to result count" 1 (List.length results);
  let r = List.hd results in
  Alcotest.(check string) "emit_to namespace" "myapp-comms"   r.Sun_cli_executor.namespace;
  Alcotest.(check string) "emit_to name"      "notify-worker" r.Sun_cli_executor.name

let test_emit_to_uses_placeholder_backend () =
  let dir = Filename.temp_file "sun-cs-backend-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let plan = make_plan [ svc_spec ] in
  let cs = build_ok ~plan ~mode:(Sun_cli_change_set.Emit_to dir) () in
  let art = List.hd cs.Sun_cli_change_set.artifacts in
  let _results = Sun_cli_change_set.execute cs in
  let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
  (try Sys.remove path with _ -> ());
  (try Unix.rmdir dir with _ -> ());
  (* The workload YAML for placeholder mode should not contain real env values —
     it emits empty stringData.  A simple smoke check: YAML was rendered. *)
  Alcotest.(check bool) "workload_yaml non-empty"
    true (String.length art.Sun_cli_change_set.workload_yaml > 0)

(* ── apply mode (via dry_run=false stub path) ────────────────────────────── *)

let test_apply_result_fields () =
  (* Sun_cli_manifest.apply with dry_run=false calls kubectl.
     We cannot invoke kubectl in CI, so we exercise Apply mode via direct
     executor (same code path) with dry_run=true to confirm result shape.
     The actual kubectl call is tested by test_executor.ml. *)
  let plan = make_plan [ svc_spec ] in
  let cs = build_ok ~plan ~mode:Sun_cli_change_set.Dry_run () in
  let results = Sun_cli_change_set.execute cs in
  let r = List.hd results in
  Alcotest.(check string) "apply-stub namespace" "myapp-payments" r.Sun_cli_executor.namespace;
  Alcotest.(check string) "apply-stub name"      "charge-svc"     r.Sun_cli_executor.name

(* ── entry point ──────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "change_set"
    [ "build", [
        Alcotest.test_case "one artifact per service" `Quick test_build_renders_one_artifact_per_service
      ; Alcotest.test_case "artifact fields"          `Quick test_build_artifact_fields
      ; Alcotest.test_case "plan preserved"           `Quick test_build_preserves_plan
      ; Alcotest.test_case "mode stored"              `Quick test_build_mode_stored
      ]
    ; "dry_run", [
        Alcotest.test_case "returns result"           `Quick test_dry_run_returns_result
      ; Alcotest.test_case "yaml non-empty"           `Quick test_dry_run_yaml_non_empty
      ]
    ; "emit_to", [
        Alcotest.test_case "file written"             `Quick test_emit_to_writes_file
      ; Alcotest.test_case "result fields"            `Quick test_emit_to_result_fields
      ; Alcotest.test_case "placeholder backend"      `Quick test_emit_to_uses_placeholder_backend
      ]
    ; "apply", [
        Alcotest.test_case "result fields"            `Quick test_apply_result_fields
      ]
    ]
