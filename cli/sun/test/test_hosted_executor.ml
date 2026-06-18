let check_string = Alcotest.(check string)

let contains_substring ~needle s =
  let ln = String.length needle in
  let ls = String.length s in
  if ln = 0 then true
  else if ln > ls then false
  else
    let rec go i =
      if i > ls - ln then false
      else if String.sub s i ln = needle then true
      else go (i + 1)
    in
    go 0

let get_ok = function
  | Ok v -> v
  | Error msg -> Alcotest.fail msg

let cpu s =
  match Sun_cli_toml.cpu_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Alcotest.fail message

let memory s =
  match Sun_cli_toml.memory_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Alcotest.fail message

let service ?(name = "charge-svc") ?(primitive = Sun_cli_deployment_plan.Svc) () =
  { Sun_cli_deployment_plan.domain = "payments";
    source_name = name;
    k8s_name = name;
    namespace = "pluto-payments";
    primitive;
    source_dir = "payments/" ^ name;
    image = "registry.sun.dev/acct_123/pluto/" ^ name ^ ":abc123";
    config = [ ("RUST_LOG", "info") ];
    secrets = [ ("DATABASE_URL", "ignored-secret-ref") ];
    schedule = None;
    replicas = 2;
    cpu = cpu "250m";
    memory = memory "256Mi";
    rollout_strategy = None;
    ingress_host = None;
    ingress_path = None;
    extra_labels = [];
    progressive_delivery = None;
  }

let hosted_plan ?(mode = Sun_cli_deployment_plan.Sun_hosted) () =
  let env : Sun_cli_deployment_plan.env_config = {
    name = "production";
    mode;
    registry = "registry.sun.dev/acct_123";
    image_tag = "abc123";
    region = Some "us-east-1";
    base_domain = Some "sun.example";
    secret_backend = Sun_cli_manifest.Kubernetes_placeholder;
  } in
  { Sun_cli_deployment_plan.workspace = "pluto";
    environment = env;
    services = [ service (); service ~name:"notify-worker" ~primitive:Worker () ];
    topics = [];
    migrations = [];
    schema_subjects = [];
    consumer_groups = [];
  }

let target_for plan =
  let account =
    Sun_cli_hosted_model.make_account
      ~account_id:"acct_123"
      ~display_name:"Acme"
      ~billing_state:Sun_cli_hosted_model.Billing_ready
      ~spend_cap_cents:50_000
      ()
    |> get_ok
  in
  let project =
    Sun_cli_hosted_model.make_project
      ~project_id:"proj_123"
      ~account
      ~workspace:"pluto"
      ~display_name:"Pluto"
    |> get_ok
  in
  let runtime =
    Sun_cli_hosted_model.make_runtime
      ~runtime_id:"rt_123"
      ~account
      ~region:"us-east-1"
      ()
    |> get_ok
  in
  let environment =
    Sun_cli_hosted_model.make_environment
      ~environment_id:"env_prod"
      ~account
      ~project
      ~runtime
      ~name:"production"
    |> get_ok
  in
  Sun_cli_hosted_model.release_target
    ~account ~project ~runtime ~environment ~plan
  |> get_ok

let request ?serialized_plan ?image_refs plan =
  { Sun_cli_hosted_executor.target = target_for plan;
    plan;
    serialized_plan = Option.value serialized_plan
        ~default:(Sun_cli_deployment_plan.to_json plan);
    image_refs = Option.value image_refs
        ~default:(Sun_cli_hosted_executor.image_refs_of_plan plan);
  }

let test_mock_submit_returns_release_shape () =
  let plan = hosted_plan () in
  let release = Sun_cli_hosted_executor.submit_mock (request plan) |> get_ok in
  check_string "release id" "rel_env-prod_abc123" release.release_id;
  check_string "environment id" "env_prod" release.environment_id;
  check_string "environment name" "production" release.environment_name;
  check_string "status" "mock_submitted"
    (Sun_cli_hosted_executor.release_status_to_string release.status);
  Alcotest.(check int) "service count" 2 (List.length release.services);
  Alcotest.(check int) "inspection service count" 2
    release.inspection.plan.service_count;
  check_string "inspection environment" "production"
    release.inspection.environment_name;
  let json = Yojson.Safe.to_string (Sun_cli_hosted_executor.release_to_json release) in
  if not (String.contains json '{') then Alcotest.fail "expected JSON object";
  if not (contains_substring ~needle:"inspection" json) then
    Alcotest.fail "expected inspection JSON"

let test_svc_has_default_url () =
  let plan = hosted_plan () in
  let release = Sun_cli_hosted_executor.submit_mock (request plan) |> get_ok in
  let svc = List.find
      (fun (s : Sun_cli_hosted_executor.service_summary) -> s.primitive = Sun_cli_deployment_plan.Svc)
      release.services in
  check_string "svc default_url"
    "charge-svc.pluto.production.apps.sun.example"
    (Option.get svc.default_url)

let test_worker_has_no_default_url () =
  let plan = hosted_plan () in
  let release = Sun_cli_hosted_executor.submit_mock (request plan) |> get_ok in
  let worker = List.find
      (fun (s : Sun_cli_hosted_executor.service_summary) -> s.primitive = Sun_cli_deployment_plan.Worker)
      release.services in
  Alcotest.(check bool) "worker default_url absent" true
    (Option.is_none worker.default_url)

let test_default_url_in_json () =
  let plan = hosted_plan () in
  let release = Sun_cli_hosted_executor.submit_mock (request plan) |> get_ok in
  let json = Sun_cli_hosted_executor.release_to_json release in
  let open Yojson.Safe.Util in
  let services = json |> member "services" |> to_list in
  let svc_json = List.find
      (fun j -> j |> member "primitive" |> to_string = "svc")
      services in
  check_string "default_url in json"
    "charge-svc.pluto.production.apps.sun.example"
    (svc_json |> member "default_url" |> to_string)

let test_no_base_domain_no_url () =
  let plan = {
    (hosted_plan ()) with
    environment = {
      (hosted_plan ()).environment with
      base_domain = None;
    };
  } in
  let release = Sun_cli_hosted_executor.submit_mock (request plan) |> get_ok in
  let svc = List.find
      (fun (s : Sun_cli_hosted_executor.service_summary) -> s.primitive = Sun_cli_deployment_plan.Svc)
      release.services in
  Alcotest.(check bool) "no url without base_domain" true
    (Option.is_none svc.default_url)

let test_uses_supplied_image_refs () =
  let plan = hosted_plan () in
  let image_refs = [
    { Sun_cli_hosted_executor.service_name = "charge-svc";
      image = "ghcr.io/acme/charge@sha256:111"; };
    { Sun_cli_hosted_executor.service_name = "notify-worker";
      image = "ghcr.io/acme/notify@sha256:222"; };
  ] in
  let release =
    Sun_cli_hosted_executor.submit_mock (request ~image_refs plan) |> get_ok
  in
  match release.services with
  | first :: _ ->
    check_string "image ref" "ghcr.io/acme/charge@sha256:111" first.image
  | [] -> Alcotest.fail "expected services"

let test_rejects_missing_image_ref () =
  let plan = hosted_plan () in
  let image_refs = [
    { Sun_cli_hosted_executor.service_name = "charge-svc";
      image = "ghcr.io/acme/charge@sha256:111"; };
  ] in
  match Sun_cli_hosted_executor.submit_mock (request ~image_refs plan) with
  | Ok _ -> Alcotest.fail "expected missing image ref rejection"
  | Error msg ->
    check_string "error" "missing hosted image ref for service notify-worker" msg

let test_rejects_serialized_plan_mismatch () =
  let plan = hosted_plan () in
  let serialized_plan = `Assoc [ "workspace", `String "other" ] in
  match Sun_cli_hosted_executor.submit_mock (request ~serialized_plan plan) with
  | Ok _ -> Alcotest.fail "expected serialized plan mismatch"
  | Error msg ->
    check_string "error" "serialized deployment plan does not match request plan" msg

let test_rejects_non_hosted_plan () =
  let plan = hosted_plan ~mode:Sun_cli_deployment_plan.Customer_cloud () in
  let target = {
    Sun_cli_hosted_model.account_id = "acct_123";
    project_id = "proj_123";
    environment_id = "env_prod";
    runtime_id = "rt_123";
    workspace = "pluto";
    environment_name = "production";
  } in
  let req = {
    Sun_cli_hosted_executor.target;
    plan;
    serialized_plan = Sun_cli_deployment_plan.to_json plan;
    image_refs = Sun_cli_hosted_executor.image_refs_of_plan plan;
  } in
  match Sun_cli_hosted_executor.submit_mock req with
  | Ok _ -> Alcotest.fail "expected non-hosted rejection"
  | Error msg ->
    check_string "error" "deployment plan is not for sun_hosted mode" msg

let () =
  Alcotest.run "hosted_executor"
    [ "mock submission", [
        Alcotest.test_case "release shape" `Quick test_mock_submit_returns_release_shape;
        Alcotest.test_case "supplied image refs" `Quick test_uses_supplied_image_refs;
        Alcotest.test_case "missing image ref" `Quick test_rejects_missing_image_ref;
        Alcotest.test_case "serialized mismatch" `Quick test_rejects_serialized_plan_mismatch;
        Alcotest.test_case "non-hosted plan" `Quick test_rejects_non_hosted_plan;
      ];
      "default url", [
        Alcotest.test_case "svc has default url" `Quick test_svc_has_default_url;
        Alcotest.test_case "worker has no url" `Quick test_worker_has_no_default_url;
        Alcotest.test_case "default url in json" `Quick test_default_url_in_json;
        Alcotest.test_case "no url without base_domain" `Quick test_no_base_domain_no_url;
      ];
    ]
