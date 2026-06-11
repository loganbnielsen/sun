let check_string = Alcotest.(check string)

let get_ok = function
  | Ok v -> v
  | Error msg -> Alcotest.fail msg

let hosted_plan ?(workspace = "pluto") ?(environment_name = "production") () =
  let env : Sun_cli_deployment_plan.env_config = {
    name = environment_name;
    mode = Sun_cli_deployment_plan.Sun_hosted;
    registry = "registry.sun.dev/acct_123";
    image_tag = "abc123";
    region = Some "us-east-1";
    base_domain = Some "sun.example";
  } in
  { Sun_cli_deployment_plan.workspace;
    environment = env;
    services = [];
    topics = [];
    migrations = [];
  }

let fixture () =
  let account =
    Sun_cli_hosted_model.make_account
      ~account_id:"acct_123"
      ~display_name:"Acme"
      ~billing_state:Sun_cli_hosted_model.Billing_ready
      ~spend_cap_cents:50000
      ~approval_threshold_cents:25000
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
      ~base_domain:"sun.example"
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
  (account, project, runtime, environment)

let test_account_fields () =
  let account, _, _, _ = fixture () in
  check_string "account id" "acct_123" account.Sun_cli_hosted_model.account_id;
  check_string "billing" "ready"
    (Sun_cli_hosted_model.billing_state_to_string account.billing_state);
  Alcotest.(check (option int)) "spend cap" (Some 50000) account.spend_cap_cents

let test_single_tenant_runtime () =
  let account, _, runtime, _ = fixture () in
  check_string "account link" account.account_id runtime.account_id;
  check_string "tenancy" "single_tenant"
    (Sun_cli_hosted_model.tenancy_to_string runtime.tenancy);
  check_string "kind" "kubernetes"
    (Sun_cli_hosted_model.runtime_kind_to_string runtime.kind)

let test_secret_scope () =
  let account, project, _, environment = fixture () in
  let scope =
    Sun_cli_hosted_model.secret_scope ~account ~project ~environment
    |> get_ok
  in
  check_string "account" account.account_id scope.account_id;
  check_string "project" project.project_id scope.project_id;
  check_string "environment" environment.environment_id scope.environment_id;
  let json = Yojson.Safe.to_string (Sun_cli_hosted_model.secret_scope_to_json scope) in
  if String.contains json ':' = false then Alcotest.fail "expected JSON object"

let test_spend_guardrail_within_cap () =
  let account, _, _, _ = fixture () in
  let guardrail =
    Sun_cli_hosted_model.evaluate_spend_guardrail
      ~account
      ~current_spend_cents:10000
    |> get_ok
  in
  check_string "status" "within_cap"
    (Sun_cli_hosted_model.cap_status_to_string guardrail.status);
  check_string "behavior" "continue_with_alert"
    (Sun_cli_hosted_model.cap_behavior_to_string guardrail.behavior);
  let json =
    Yojson.Safe.to_string
      (Sun_cli_hosted_model.spend_guardrail_to_json guardrail)
  in
  if not (String.contains json '{') then Alcotest.fail "expected JSON object"

let test_spend_guardrail_requires_approval () =
  let account, _, _, _ = fixture () in
  let guardrail =
    Sun_cli_hosted_model.evaluate_spend_guardrail
      ~account
      ~current_spend_cents:25000
    |> get_ok
  in
  check_string "status" "approval_required"
    (Sun_cli_hosted_model.cap_status_to_string guardrail.status);
  check_string "behavior" "require_manual_approval"
    (Sun_cli_hosted_model.cap_behavior_to_string guardrail.behavior)

let test_spend_guardrail_blocks_at_cap () =
  let account, _, _, _ = fixture () in
  let guardrail =
    Sun_cli_hosted_model.evaluate_spend_guardrail
      ~account
      ~current_spend_cents:50000
    |> get_ok
  in
  check_string "status" "cap_reached"
    (Sun_cli_hosted_model.cap_status_to_string guardrail.status);
  check_string "behavior" "block_new_hosted_resources"
    (Sun_cli_hosted_model.cap_behavior_to_string guardrail.behavior)

let test_cost_attribution_record () =
  let _, _, runtime, environment = fixture () in
  let attribution =
    Sun_cli_hosted_model.make_cost_attribution
      ~attribution_id:"attr_123"
      ~environment
      ~runtime
      ~billing_period:"2026-06"
      ~provider:"aws"
      ~provider_resource_id:"arn:aws:eks:us-east-1:123:cluster/sun"
      ~resource_kind:"eks_cluster"
      ~observed_cost_cents:12345
      ~currency:"USD"
      ~metadata:["provider_region", "us-east-1"; "source", "manual"]
      ()
    |> get_ok
  in
  check_string "account" environment.account_id attribution.account_id;
  check_string "environment" environment.environment_id attribution.environment_id;
  let json =
    Yojson.Safe.to_string
      (Sun_cli_hosted_model.cost_attribution_to_json attribution)
  in
  if not (String.contains json '{') then Alcotest.fail "expected JSON object"

let test_early_cost_plus_billing_record () =
  let account, _, _, environment = fixture () in
  let record =
    Sun_cli_hosted_model.make_early_cost_plus_billing_record
      ~account
      ~environment
      ~billing_period:"2026-06"
      ~provider_cost_cents:10000
      ~markup_basis_points:20000
      ~currency:"USD"
      ~status:Sun_cli_hosted_model.Billing_record_pending_review
    |> get_ok
  in
  Alcotest.(check int) "charge" 20000 record.charge_amount_cents;
  check_string "status" "pending_review"
    (Sun_cli_hosted_model.billing_record_status_to_string record.status);
  let json =
    Yojson.Safe.to_string
      (Sun_cli_hosted_model.early_cost_plus_billing_record_to_json record)
  in
  if not (String.contains json '{') then Alcotest.fail "expected JSON object"

let test_release_target_success () =
  let account, project, runtime, environment = fixture () in
  let target =
    Sun_cli_hosted_model.release_target
      ~account ~project ~runtime ~environment ~plan:(hosted_plan ())
    |> get_ok
  in
  check_string "workspace" "pluto" target.workspace;
  check_string "environment" "production" target.environment_name;
  check_string "runtime" runtime.runtime_id target.runtime_id;
  let json = Yojson.Safe.to_string (Sun_cli_hosted_model.release_target_to_json target) in
  if not (String.contains json '{') then Alcotest.fail "expected JSON object"

let test_release_target_rejects_workspace_mismatch () =
  let account, project, runtime, environment = fixture () in
  match Sun_cli_hosted_model.release_target
          ~account ~project ~runtime ~environment
          ~plan:(hosted_plan ~workspace:"venus" ()) with
  | Ok _ -> Alcotest.fail "expected workspace mismatch"
  | Error msg ->
    check_string "error" "deployment plan workspace does not match hosted project" msg

let test_release_target_rejects_environment_mismatch () =
  let account, project, runtime, environment = fixture () in
  match Sun_cli_hosted_model.release_target
          ~account ~project ~runtime ~environment
          ~plan:(hosted_plan ~environment_name:"staging" ()) with
  | Ok _ -> Alcotest.fail "expected environment mismatch"
  | Error msg ->
    check_string "error" "deployment plan environment does not match hosted environment" msg

let test_release_target_rejects_non_hosted_plan () =
  let account, project, runtime, environment = fixture () in
  let plan = hosted_plan () in
  let plan = {
    plan with
    Sun_cli_deployment_plan.environment = {
      plan.environment with mode = Sun_cli_deployment_plan.Customer_cloud;
    };
  } in
  match Sun_cli_hosted_model.release_target
          ~account ~project ~runtime ~environment ~plan with
  | Ok _ -> Alcotest.fail "expected non-hosted rejection"
  | Error msg ->
    check_string "error" "deployment plan is not for sun_hosted mode" msg

let test_environment_rejects_cross_account_runtime () =
  let account, project, _, _ = fixture () in
  let other_account =
    Sun_cli_hosted_model.make_account
      ~account_id:"acct_other"
      ~display_name:"Other"
      ~billing_state:Sun_cli_hosted_model.Billing_ready
      ()
    |> get_ok
  in
  let other_runtime =
    Sun_cli_hosted_model.make_runtime
      ~runtime_id:"rt_other"
      ~account:other_account
      ()
    |> get_ok
  in
  match Sun_cli_hosted_model.make_environment
          ~environment_id:"env_bad"
          ~account
          ~project
          ~runtime:other_runtime
          ~name:"production" with
  | Ok _ -> Alcotest.fail "expected cross-account runtime rejection"
  | Error msg ->
    check_string "error" "runtime does not belong to project account" msg

let test_environment_requires_payment_ready_account () =
  let account =
    Sun_cli_hosted_model.make_account
      ~account_id:"acct_unpaid"
      ~display_name:"Unpaid"
      ~billing_state:Sun_cli_hosted_model.Billing_needs_payment_method
      ~spend_cap_cents:50000
      ()
    |> get_ok
  in
  let project =
    Sun_cli_hosted_model.make_project
      ~project_id:"proj_unpaid"
      ~account
      ~workspace:"pluto"
      ~display_name:"Pluto"
    |> get_ok
  in
  let runtime =
    Sun_cli_hosted_model.make_runtime
      ~runtime_id:"rt_unpaid"
      ~account
      ()
    |> get_ok
  in
  match Sun_cli_hosted_model.make_environment
          ~environment_id:"env_unpaid"
          ~account
          ~project
          ~runtime
          ~name:"production" with
  | Ok _ -> Alcotest.fail "expected payment readiness rejection"
  | Error msg ->
    check_string "error"
      "account payment method is required before hosted environment creation" msg

let test_environment_requires_spend_cap () =
  let account =
    Sun_cli_hosted_model.make_account
      ~account_id:"acct_nocap"
      ~display_name:"No Cap"
      ~billing_state:Sun_cli_hosted_model.Billing_ready
      ()
    |> get_ok
  in
  let project =
    Sun_cli_hosted_model.make_project
      ~project_id:"proj_nocap"
      ~account
      ~workspace:"pluto"
      ~display_name:"Pluto"
    |> get_ok
  in
  let runtime =
    Sun_cli_hosted_model.make_runtime
      ~runtime_id:"rt_nocap"
      ~account
      ()
    |> get_ok
  in
  match Sun_cli_hosted_model.make_environment
          ~environment_id:"env_nocap"
          ~account
          ~project
          ~runtime
          ~name:"production" with
  | Ok _ -> Alcotest.fail "expected spend cap rejection"
  | Error msg ->
    check_string "error"
      "account spend cap is required before hosted environment creation" msg

let test_account_rejects_threshold_above_cap () =
  match Sun_cli_hosted_model.make_account
          ~account_id:"acct_bad_threshold"
          ~display_name:"Bad Threshold"
          ~billing_state:Sun_cli_hosted_model.Billing_ready
          ~spend_cap_cents:10000
          ~approval_threshold_cents:10001
          () with
  | Ok _ -> Alcotest.fail "expected threshold rejection"
  | Error msg ->
    check_string "error"
      "approval_threshold_cents must not exceed spend_cap_cents" msg

let test_invalid_id () =
  match Sun_cli_hosted_model.make_account
          ~account_id:"bad id"
          ~display_name:"Bad"
          ~billing_state:Sun_cli_hosted_model.Billing_ready
          () with
  | Ok _ -> Alcotest.fail "expected invalid id"
  | Error msg ->
    check_string "error" {|account_id "bad id" contains unsupported characters|} msg

let () =
  Alcotest.run "hosted_model"
    [ "identity", [
        Alcotest.test_case "account fields" `Quick test_account_fields;
        Alcotest.test_case "single tenant runtime" `Quick test_single_tenant_runtime;
        Alcotest.test_case "invalid id" `Quick test_invalid_id;
      ];
      "billing guardrails", [
        Alcotest.test_case "within cap" `Quick test_spend_guardrail_within_cap;
        Alcotest.test_case "approval required" `Quick test_spend_guardrail_requires_approval;
        Alcotest.test_case "cap reached" `Quick test_spend_guardrail_blocks_at_cap;
        Alcotest.test_case "cost attribution" `Quick test_cost_attribution_record;
        Alcotest.test_case "early cost-plus record" `Quick test_early_cost_plus_billing_record;
        Alcotest.test_case "spend cap required" `Quick test_environment_requires_spend_cap;
        Alcotest.test_case "threshold above cap" `Quick test_account_rejects_threshold_above_cap;
      ];
      "scopes", [
        Alcotest.test_case "secret scope" `Quick test_secret_scope;
        Alcotest.test_case "release target success" `Quick test_release_target_success;
        Alcotest.test_case "cross-account runtime" `Quick test_environment_rejects_cross_account_runtime;
        Alcotest.test_case "payment ready account" `Quick test_environment_requires_payment_ready_account;
        Alcotest.test_case "workspace mismatch" `Quick test_release_target_rejects_workspace_mismatch;
        Alcotest.test_case "environment mismatch" `Quick test_release_target_rejects_environment_mismatch;
        Alcotest.test_case "non-hosted plan" `Quick test_release_target_rejects_non_hosted_plan;
      ];
    ]
