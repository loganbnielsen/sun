(* Tests for Sun_cli_deployment_pipeline.
   All tests construct plans and artifacts purely in-memory — no subprocess
   calls, no kubectl, no docker. *)

let k8s_name value =
  match Sun_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
  | Error err -> Alcotest.fail (Sun_cli_deployment_plan.plan_error_to_string err)

let namespace ~workspace ~domain =
  Sun_cli_deployment_plan.namespace_of ~workspace ~domain

let make_svc_spec ?(domain = "payments") name : Sun_cli_deployment_plan.service_spec = {
  domain;
  source_name           = name;
  k8s_name              = k8s_name (String.map (fun c -> if c = '_' then '-' else c) name);
  namespace             = namespace ~workspace:"myapp" ~domain;
  primitive             = Sun_cli_deployment_plan.Svc;
  source_dir            = "app/" ^ domain ^ "/" ^ name;
  image                 = "sun-registry:5000/myapp/" ^ name ^ ":abc123";
  config                = [("LOG_LEVEL", "info")];
  secrets               = [("DB_PASSWORD", "")];
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

let make_worker_spec ?(domain = "comms") name : Sun_cli_deployment_plan.service_spec = {
  (make_svc_spec ~domain name) with
  primitive = Sun_cli_deployment_plan.Worker;
}

let make_fn_spec ?(domain = "billing") name : Sun_cli_deployment_plan.service_spec = {
  (make_svc_spec ~domain name) with
  primitive = Sun_cli_deployment_plan.Fn;
  schedule  = Some "0 * * * *";
}

let sample_env_config () : Sun_cli_deployment_plan.env_config = {
  name           = "production";
  mode           = Sun_cli_deployment_plan.Customer_cloud;
  registry       = "123.dkr.ecr.us-east-1.amazonaws.com";
  image_tag      = "abc1234";
  region         = Some "us-east-1";
  base_domain    = None;
  secret_backend = Sun_cli_manifest.Kubernetes_placeholder;
}

let sample_plan () : Sun_cli_deployment_plan.t = {
  workspace       = "myapp";
  environment     = sample_env_config ();
  services        = [make_svc_spec "charge-svc"; make_worker_spec "notify-worker"];
  topics          = ["payments.charged"];
  migrations      = [];
  schema_subjects = [];
  consumer_groups = ["myapp.comms.notify_worker"];
}

(* ── Phase 2: resolve_local ──────────────────────────────────────────────── *)

let test_resolve_local_sets_registry () =
  let env = Sun_cli_deployment_pipeline.resolve_local
    ~image_tag:"abc123" ~workspace:"myapp" in
  Alcotest.(check string) "registry"
    "sun-registry:5000"
    (Sun_cli_env_target.registry env.Sun_cli_deployment_pipeline.env_target)

let test_resolve_local_env_config_name () =
  let env = Sun_cli_deployment_pipeline.resolve_local
    ~image_tag:"abc123" ~workspace:"myapp" in
  Alcotest.(check string) "env_config name"
    "myapp"
    env.Sun_cli_deployment_pipeline.env_config.Sun_cli_deployment_plan.name

let test_resolve_local_image_tag () =
  let env = Sun_cli_deployment_pipeline.resolve_local
    ~image_tag:"sha-deadbeef" ~workspace:"myapp" in
  Alcotest.(check string) "image_tag"
    "sha-deadbeef"
    env.Sun_cli_deployment_pipeline.env_config.Sun_cli_deployment_plan.image_tag

(* ── Phase 2: resolve_customer_cloud ─────────────────────────────────────── *)

let test_resolve_customer_cloud_ok () =
  match Sun_cli_deployment_pipeline.resolve_customer_cloud
    ~registry:"123.dkr.ecr.us-east-1.amazonaws.com"
    ~image_tag:"abc123"
    ~workspace:"myapp"
    ~emit_to:None
    ~secret_backend:Sun_cli_manifest.Kubernetes_placeholder
  with
  | Ok env ->
    Alcotest.(check string) "registry"
      "123.dkr.ecr.us-east-1.amazonaws.com"
      env.Sun_cli_deployment_pipeline.env_config.Sun_cli_deployment_plan.registry
  | Error err ->
    Alcotest.fail (Sun_cli_deployment_pipeline.pipeline_error_to_string err)

let test_resolve_customer_cloud_empty_registry_fails () =
  match Sun_cli_deployment_pipeline.resolve_customer_cloud
    ~registry:""
    ~image_tag:"abc123"
    ~workspace:"myapp"
    ~emit_to:None
    ~secret_backend:Sun_cli_manifest.Kubernetes_placeholder
  with
  | Error (Sun_cli_deployment_pipeline.Env_validation_error _) -> ()
  | Ok _ -> Alcotest.fail "expected validation error for empty registry"
  | Error err ->
    Alcotest.fail (Printf.sprintf "unexpected error: %s"
      (Sun_cli_deployment_pipeline.pipeline_error_to_string err))

let test_resolve_customer_cloud_gitops_emit_to () =
  match Sun_cli_deployment_pipeline.resolve_customer_cloud
    ~registry:"my.registry.io"
    ~image_tag:"v1"
    ~workspace:"ws"
    ~emit_to:(Some "/tmp/gitops")
    ~secret_backend:Sun_cli_manifest.Kubernetes_placeholder
  with
  | Ok env ->
    let target = Sun_cli_env_target.target env.Sun_cli_deployment_pipeline.env_target in
    Alcotest.(check bool) "gitops target"
      true (target = Sun_cli_env_target.Customer_k8s_gitops)
  | Error err ->
    Alcotest.fail (Sun_cli_deployment_pipeline.pipeline_error_to_string err)

(* ── Phase 3: build_plan ─────────────────────────────────────────────────── *)

let base_request workspace : Sun_cli_deployment_pipeline.request = {
  workspace;
  image_tag            = "abc123";
  filter_path          = None;
  emit_to              = None;
  secret_backend       = Sun_cli_manifest.Kubernetes_placeholder;
  confirm_group_change = false;
  dry_run              = false;
}

let with_cwd dir f =
  let orig = Sys.getcwd () in
  Sys.chdir dir;
  Fun.protect f ~finally:(fun () -> Sys.chdir orig)

let mkdirs path =
  let parts = String.split_on_char '/' path in
  ignore (List.fold_left (fun acc part ->
    let p = if acc = "" then part else acc ^ "/" ^ part in
    (if p <> "" && not (Sys.file_exists p) then Unix.mkdir p 0o755);
    p
  ) "" parts)

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let minimal_toml = "[infra]\n"

let make_test_service domain name prim =
  let prim_manifest = match prim with
    | `Svc -> Sun_cli_manifest.Svc
    | `Worker -> Sun_cli_manifest.Worker
    | `Fn -> Sun_cli_manifest.Fn
  in
  ({ Sun_cli_manifest.domain; name; prim = prim_manifest;
     dir = Printf.sprintf "app/%s/%s" domain name })

let test_build_plan_constructs_plan () =
  let tmp = Filename.temp_dir "sun_pipeline_test" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file "app/payments/charge_svc/sun.toml" minimal_toml;
    let services = [make_test_service "payments" "charge_svc" `Svc] in
    let env = Sun_cli_deployment_pipeline.resolve_local ~image_tag:"abc123" ~workspace:"myapp" in
    let req = base_request "myapp" in
    match Sun_cli_deployment_pipeline.build_plan req env services with
    | Ok plan ->
      Alcotest.(check string) "workspace" "myapp" plan.Sun_cli_deployment_plan.workspace;
      Alcotest.(check int) "one service" 1 (List.length plan.Sun_cli_deployment_plan.services)
    | Error err ->
      Alcotest.fail (Sun_cli_deployment_pipeline.pipeline_error_to_string err)
  )

let test_build_plan_no_services_returns_plan () =
  let tmp = Filename.temp_dir "sun_pipeline_empty" "" in
  with_cwd tmp (fun () ->
    let env = Sun_cli_deployment_pipeline.resolve_local ~image_tag:"abc123" ~workspace:"myapp" in
    let req = base_request "myapp" in
    match Sun_cli_deployment_pipeline.build_plan req env [] with
    | Ok plan ->
      Alcotest.(check int) "zero services" 0 (List.length plan.Sun_cli_deployment_plan.services)
    | Error err ->
      Alcotest.fail (Sun_cli_deployment_pipeline.pipeline_error_to_string err)
  )

let test_build_plan_dry_run_skips_group_guard () =
  let tmp = Filename.temp_dir "sun_pipeline_dryrun" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/comms/notify_worker";
    write_file "app/comms/notify_worker/sun.toml" minimal_toml;
    let services = [make_test_service "comms" "notify_worker" `Worker] in
    let env = Sun_cli_deployment_pipeline.resolve_local ~image_tag:"abc123" ~workspace:"myapp" in
    let req = { (base_request "myapp") with
      Sun_cli_deployment_pipeline.dry_run = true;
      confirm_group_change = false } in
    match Sun_cli_deployment_pipeline.build_plan req env services with
    | Ok plan ->
      Alcotest.(check int) "one service" 1 (List.length plan.Sun_cli_deployment_plan.services)
    | Error err ->
      Alcotest.fail (Sun_cli_deployment_pipeline.pipeline_error_to_string err)
  )

let test_build_plan_gitops_skips_group_guard () =
  let tmp = Filename.temp_dir "sun_pipeline_gitops" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/comms/notify_worker";
    write_file "app/comms/notify_worker/sun.toml" minimal_toml;
    let services = [make_test_service "comms" "notify_worker" `Worker] in
    let env = Sun_cli_deployment_pipeline.resolve_local ~image_tag:"abc123" ~workspace:"myapp" in
    let req = { (base_request "myapp") with
      Sun_cli_deployment_pipeline.emit_to = Some "/tmp/gitops";
      confirm_group_change = false } in
    match Sun_cli_deployment_pipeline.build_plan req env services with
    | Ok plan ->
      Alcotest.(check int) "one service" 1 (List.length plan.Sun_cli_deployment_plan.services)
    | Error err ->
      Alcotest.fail (Sun_cli_deployment_pipeline.pipeline_error_to_string err)
  )

(* ── Phase 4: render_artifacts ──────────────────────────────────────────── *)

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

let test_render_artifacts_count () =
  let plan = sample_plan () in
  let artifacts = Sun_cli_deployment_pipeline.render_artifacts
    ~secret_backend:Sun_cli_manifest.Kubernetes_placeholder plan in
  Alcotest.(check int) "artifact per service"
    (List.length plan.Sun_cli_deployment_plan.services)
    (List.length artifacts)

let test_render_artifacts_ns_yaml_contains_namespace () =
  let plan = sample_plan () in
  let artifacts = Sun_cli_deployment_pipeline.render_artifacts
    ~secret_backend:Sun_cli_manifest.Kubernetes_placeholder plan in
  let artifact = List.hd artifacts in
  Alcotest.(check bool) "ns_yaml contains namespace"
    true (contains artifact.Sun_cli_deployment_pipeline.ns_yaml "myapp-payments")

let test_render_artifacts_workload_yaml_contains_image () =
  let plan = sample_plan () in
  let artifacts = Sun_cli_deployment_pipeline.render_artifacts
    ~secret_backend:Sun_cli_manifest.Kubernetes_placeholder plan in
  let artifact = List.hd artifacts in
  let img = artifact.Sun_cli_deployment_pipeline.spec.Sun_cli_deployment_plan.image in
  Alcotest.(check bool) "workload_yaml contains image"
    true (contains artifact.Sun_cli_deployment_pipeline.workload_yaml img)

let test_render_artifacts_image_override () =
  let plan = { (sample_plan ()) with
    Sun_cli_deployment_plan.services = [make_svc_spec "charge-svc"] } in
  let override_image = "localhost:5000/myapp/charge-svc:dev" in
  let artifacts = Sun_cli_deployment_pipeline.render_artifacts
    ~image_override:(fun _ -> override_image)
    ~secret_backend:Sun_cli_manifest.Kubernetes_placeholder plan in
  let artifact = List.hd artifacts in
  Alcotest.(check bool) "workload_yaml uses overridden image"
    true (contains artifact.Sun_cli_deployment_pipeline.workload_yaml override_image)

let test_render_artifacts_placeholder_redacts_secrets () =
  let plan = { (sample_plan ()) with
    Sun_cli_deployment_plan.services = [
      { (make_svc_spec "charge-svc") with
        secrets = [("DB_PASSWORD", "actual-secret-value")] }
    ] } in
  let artifacts = Sun_cli_deployment_pipeline.render_artifacts
    ~secret_backend:Sun_cli_manifest.Kubernetes_placeholder plan in
  let artifact = List.hd artifacts in
  Alcotest.(check bool) "secret value not in workload_yaml"
    false (contains artifact.Sun_cli_deployment_pipeline.workload_yaml "actual-secret-value")

let test_render_artifacts_worker_no_service_resource () =
  let plan = { (sample_plan ()) with
    Sun_cli_deployment_plan.services = [make_worker_spec "notify-worker"] } in
  let artifacts = Sun_cli_deployment_pipeline.render_artifacts
    ~secret_backend:Sun_cli_manifest.Kubernetes_placeholder plan in
  let artifact = List.hd artifacts in
  Alcotest.(check bool) "worker has no Service resource (but may have ServiceAccount)"
    false (contains artifact.Sun_cli_deployment_pipeline.workload_yaml "kind: Service\n")

let test_render_artifacts_fn_has_cronjob () =
  let plan = { (sample_plan ()) with
    Sun_cli_deployment_plan.services = [make_fn_spec "invoice-fn"] } in
  let artifacts = Sun_cli_deployment_pipeline.render_artifacts
    ~secret_backend:Sun_cli_manifest.Kubernetes_placeholder plan in
  let artifact = List.hd artifacts in
  Alcotest.(check bool) "fn has CronJob"
    true (contains artifact.Sun_cli_deployment_pipeline.workload_yaml "kind: CronJob")

let test_render_artifacts_spec_preserved () =
  let plan = sample_plan () in
  let artifacts = Sun_cli_deployment_pipeline.render_artifacts
    ~secret_backend:Sun_cli_manifest.Kubernetes_placeholder plan in
  let artifact = List.hd artifacts in
  let spec = artifact.Sun_cli_deployment_pipeline.spec in
  Alcotest.(check string) "spec.source_name preserved"
    "charge-svc"
    spec.Sun_cli_deployment_plan.source_name

(* ── Phase 5: emit_artifact ──────────────────────────────────────────────── *)

let test_emit_artifact_writes_file () =
  let dir = Filename.temp_dir "sun_emit_test" "" in
  let plan = { (sample_plan ()) with
    Sun_cli_deployment_plan.services = [make_svc_spec "charge-svc"] } in
  let artifacts = Sun_cli_deployment_pipeline.render_artifacts
    ~secret_backend:Sun_cli_manifest.Kubernetes_placeholder plan in
  let artifact = List.hd artifacts in
  let result = Sun_cli_deployment_pipeline.emit_artifact ~dir artifact in
  let expected_path = Filename.concat dir
    (Printf.sprintf "%s-%s.yaml" result.Sun_cli_deployment_pipeline.namespace result.Sun_cli_deployment_pipeline.name) in
  Alcotest.(check bool) "file was created"
    true (Sys.file_exists expected_path)

let test_emit_artifact_result_namespace () =
  let dir = Filename.temp_dir "sun_emit_ns_test" "" in
  let plan = { (sample_plan ()) with
    Sun_cli_deployment_plan.services = [make_svc_spec "charge-svc"] } in
  let artifacts = Sun_cli_deployment_pipeline.render_artifacts
    ~secret_backend:Sun_cli_manifest.Kubernetes_placeholder plan in
  let artifact = List.hd artifacts in
  let result = Sun_cli_deployment_pipeline.emit_artifact ~dir artifact in
  Alcotest.(check string) "result namespace"
    "myapp-payments"
    result.Sun_cli_deployment_pipeline.namespace

(* ── error formatting ────────────────────────────────────────────────────── *)

let test_pipeline_error_to_string_env_error () =
  let msg = Sun_cli_deployment_pipeline.pipeline_error_to_string
    (Sun_cli_deployment_pipeline.Env_validation_error "registry must be set") in
  Alcotest.(check string) "env validation message"
    "registry must be set" msg

let test_pipeline_error_to_string_no_services () =
  let msg = Sun_cli_deployment_pipeline.pipeline_error_to_string
    Sun_cli_deployment_pipeline.No_services_found in
  Alcotest.(check bool) "no services message non-empty"
    true (String.length msg > 0)

let test_pipeline_error_to_string_consumer_group () =
  let msg = Sun_cli_deployment_pipeline.pipeline_error_to_string
    (Sun_cli_deployment_pipeline.Consumer_group_change
       { removed = ["myapp.comms.notify_worker"] }) in
  Alcotest.(check bool) "consumer group removal message contains group"
    true (contains msg "myapp.comms.notify_worker")

let () =
  Alcotest.run "deployment_pipeline"
    [ "resolve_local", [
        Alcotest.test_case "sets registry"        `Quick test_resolve_local_sets_registry
      ; Alcotest.test_case "env_config name"      `Quick test_resolve_local_env_config_name
      ; Alcotest.test_case "image_tag preserved"  `Quick test_resolve_local_image_tag
      ]
    ; "resolve_customer_cloud", [
        Alcotest.test_case "ok with valid registry"        `Quick test_resolve_customer_cloud_ok
      ; Alcotest.test_case "empty registry fails"          `Quick test_resolve_customer_cloud_empty_registry_fails
      ; Alcotest.test_case "emit_to sets gitops target"   `Quick test_resolve_customer_cloud_gitops_emit_to
      ]
    ; "build_plan", [
        Alcotest.test_case "constructs plan from services" `Quick test_build_plan_constructs_plan
      ; Alcotest.test_case "empty services returns ok"    `Quick test_build_plan_no_services_returns_plan
      ; Alcotest.test_case "dry_run skips group guard"    `Quick test_build_plan_dry_run_skips_group_guard
      ; Alcotest.test_case "gitops skips group guard"     `Quick test_build_plan_gitops_skips_group_guard
      ]
    ; "render_artifacts", [
        Alcotest.test_case "count matches services"       `Quick test_render_artifacts_count
      ; Alcotest.test_case "ns_yaml contains namespace"   `Quick test_render_artifacts_ns_yaml_contains_namespace
      ; Alcotest.test_case "workload_yaml contains image" `Quick test_render_artifacts_workload_yaml_contains_image
      ; Alcotest.test_case "image_override applied"       `Quick test_render_artifacts_image_override
      ; Alcotest.test_case "placeholder redacts secrets"  `Quick test_render_artifacts_placeholder_redacts_secrets
      ; Alcotest.test_case "worker has no Service"        `Quick test_render_artifacts_worker_no_service_resource
      ; Alcotest.test_case "fn has CronJob"               `Quick test_render_artifacts_fn_has_cronjob
      ; Alcotest.test_case "spec preserved in artifact"  `Quick test_render_artifacts_spec_preserved
      ]
    ; "emit_artifact", [
        Alcotest.test_case "writes file to dir"          `Quick test_emit_artifact_writes_file
      ; Alcotest.test_case "result namespace correct"     `Quick test_emit_artifact_result_namespace
      ]
    ; "pipeline_error_to_string", [
        Alcotest.test_case "env validation error"        `Quick test_pipeline_error_to_string_env_error
      ; Alcotest.test_case "no services found"           `Quick test_pipeline_error_to_string_no_services
      ; Alcotest.test_case "consumer group change"       `Quick test_pipeline_error_to_string_consumer_group
      ]
    ]
