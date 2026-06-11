type account_id = string
type project_id = string
type environment_id = string
type runtime_id = string
type attribution_id = string

type billing_state =
  | Billing_ready
  | Billing_needs_payment_method
  | Billing_suspended

type tenancy =
  | Single_tenant

type runtime_kind =
  | Kubernetes

type cap_behavior =
  | Continue_with_alert
  | Require_manual_approval
  | Block_new_hosted_resources

type cap_status =
  | Within_cap
  | Approval_required
  | Cap_reached

type billing_record_status =
  | Billing_record_open
  | Billing_record_pending_review
  | Billing_record_ready

type account = {
  account_id               : account_id;
  display_name             : string;
  billing_state            : billing_state;
  spend_cap_cents          : int option;
  approval_threshold_cents : int option;
}

type project = {
  project_id   : project_id;
  account_id   : account_id;
  workspace    : string;
  display_name : string;
}

type runtime_substrate = {
  runtime_id  : runtime_id;
  account_id  : account_id;
  tenancy     : tenancy;
  kind        : runtime_kind;
  region      : string option;
  base_domain : string option;
}

type environment = {
  account_id      : account_id;
  environment_id : environment_id;
  project_id     : project_id;
  name           : string;
  runtime_id     : runtime_id;
}

type secret_scope = {
  account_id     : account_id;
  project_id     : project_id;
  environment_id : environment_id;
}

type release_target = {
  account_id       : account_id;
  project_id       : project_id;
  environment_id   : environment_id;
  runtime_id       : runtime_id;
  workspace        : string;
  environment_name : string;
}

type spend_guardrail = {
  account_id               : account_id;
  current_spend_cents      : int;
  spend_cap_cents          : int;
  approval_threshold_cents : int option;
  status                   : cap_status;
  behavior                 : cap_behavior;
}

type cost_attribution = {
  attribution_id        : attribution_id;
  account_id            : account_id;
  project_id            : project_id;
  environment_id        : environment_id;
  runtime_id            : runtime_id;
  billing_period        : string;
  provider              : string;
  provider_resource_id  : string;
  resource_kind         : string;
  observed_cost_cents   : int;
  currency              : string;
  metadata              : (string * string) list;
}

type early_cost_plus_billing_record = {
  account_id            : account_id;
  environment_id        : environment_id;
  billing_period        : string;
  provider_cost_cents   : int;
  markup_basis_points   : int;
  charge_amount_cents   : int;
  currency              : string;
  status                : billing_record_status;
}

let billing_state_to_string = function
  | Billing_ready -> "ready"
  | Billing_needs_payment_method -> "needs_payment_method"
  | Billing_suspended -> "suspended"

let tenancy_to_string = function
  | Single_tenant -> "single_tenant"

let runtime_kind_to_string = function
  | Kubernetes -> "kubernetes"

let cap_behavior_to_string = function
  | Continue_with_alert -> "continue_with_alert"
  | Require_manual_approval -> "require_manual_approval"
  | Block_new_hosted_resources -> "block_new_hosted_resources"

let cap_status_to_string = function
  | Within_cap -> "within_cap"
  | Approval_required -> "approval_required"
  | Cap_reached -> "cap_reached"

let billing_record_status_to_string = function
  | Billing_record_open -> "open"
  | Billing_record_pending_review -> "pending_review"
  | Billing_record_ready -> "ready"

let is_id_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true
  | _ -> false

let validate_id ~field value =
  let value = String.trim value in
  if value = "" then Error (Printf.sprintf "%s must not be empty" field)
  else if not (String.for_all is_id_char value) then
    Error (Printf.sprintf "%s %S contains unsupported characters" field value)
  else Ok value

let validate_name ~field value =
  let value = String.trim value in
  if value = "" then Error (Printf.sprintf "%s must not be empty" field)
  else Ok value

let validate_currency value =
  let value = String.trim value in
  if String.length value <> 3 then Error "currency must be a 3-letter code"
  else if not (String.for_all (function 'A' .. 'Z' -> true | _ -> false) value) then
    Error "currency must be uppercase ASCII"
  else Ok value

let validate_non_negative ~field = function
  | None -> Ok None
  | Some n when n >= 0 -> Ok (Some n)
  | Some _ -> Error (Printf.sprintf "%s must be non-negative" field)

let validate_non_negative_int ~field n =
  if n >= 0 then Ok n
  else Error (Printf.sprintf "%s must be non-negative" field)

let validate_positive_int ~field n =
  if n > 0 then Ok n
  else Error (Printf.sprintf "%s must be positive" field)

let ( let* ) = Result.bind

let make_account
    ~account_id
    ~display_name
    ~billing_state
    ?spend_cap_cents
    ?approval_threshold_cents
    () =
  let* account_id = validate_id ~field:"account_id" account_id in
  let* display_name = validate_name ~field:"account display_name" display_name in
  let* spend_cap_cents =
    validate_non_negative ~field:"spend_cap_cents" spend_cap_cents
  in
  let* approval_threshold_cents =
    validate_non_negative ~field:"approval_threshold_cents" approval_threshold_cents
  in
  let* () =
    match spend_cap_cents, approval_threshold_cents with
    | Some spend_cap_cents, Some approval_threshold_cents
      when approval_threshold_cents > spend_cap_cents ->
      Error "approval_threshold_cents must not exceed spend_cap_cents"
    | _ -> Ok ()
  in
  Ok { account_id; display_name; billing_state; spend_cap_cents; approval_threshold_cents }

let make_project ~project_id ~(account : account) ~workspace ~display_name =
  let* project_id = validate_id ~field:"project_id" project_id in
  let* workspace = validate_id ~field:"workspace" workspace in
  let* display_name = validate_name ~field:"project display_name" display_name in
  Ok { project_id; account_id = account.account_id; workspace; display_name }

let make_runtime ~runtime_id ~(account : account) ?region ?base_domain () =
  let* runtime_id = validate_id ~field:"runtime_id" runtime_id in
  Ok {
    runtime_id;
    account_id = account.account_id;
    tenancy = Single_tenant;
    kind = Kubernetes;
    region;
    base_domain;
  }

let make_environment
    ~environment_id
    ~(account : account)
    ~(project : project)
    ~(runtime : runtime_substrate)
    ~name =
  let* environment_id = validate_id ~field:"environment_id" environment_id in
  let* name = validate_id ~field:"environment name" name in
  if project.account_id <> account.account_id then
    Error "project does not belong to account"
  else if runtime.account_id <> account.account_id then
    Error "runtime does not belong to project account"
  else if account.billing_state = Billing_needs_payment_method then
    Error "account payment method is required before hosted environment creation"
  else if account.billing_state = Billing_suspended then
    Error "account billing is suspended"
  else if account.spend_cap_cents = None then
    Error "account spend cap is required before hosted environment creation"
  else
    Ok {
      account_id = account.account_id;
      environment_id;
      project_id = project.project_id;
      name;
      runtime_id = runtime.runtime_id;
    }

let secret_scope
    ~(account : account)
    ~(project : project)
    ~(environment : environment) =
  if project.account_id <> account.account_id then
    Error "project does not belong to account"
  else if environment.project_id <> project.project_id then
    Error "environment does not belong to project"
  else if environment.account_id <> account.account_id then
    Error "environment does not belong to account"
  else
    Ok {
      account_id = account.account_id;
      project_id = project.project_id;
      environment_id = environment.environment_id;
    }

let release_target
    ~(account : account)
    ~(project : project)
    ~(environment : environment)
    ~(runtime : runtime_substrate)
    ~plan =
  if project.account_id <> account.account_id then
    Error "project does not belong to account"
  else if runtime.account_id <> account.account_id then
    Error "runtime does not belong to account"
  else if environment.account_id <> account.account_id then
    Error "environment does not belong to account"
  else if environment.project_id <> project.project_id then
    Error "environment does not belong to project"
  else if environment.runtime_id <> runtime.runtime_id then
    Error "environment is not attached to runtime"
  else if project.workspace <> plan.Sun_cli_deployment_plan.workspace then
    Error "deployment plan workspace does not match hosted project"
  else if environment.name <> plan.Sun_cli_deployment_plan.environment.name then
    Error "deployment plan environment does not match hosted environment"
  else if plan.Sun_cli_deployment_plan.environment.mode <> Sun_cli_deployment_plan.Sun_hosted then
    Error "deployment plan is not for sun_hosted mode"
  else
    Ok {
      account_id = account.account_id;
      project_id = project.project_id;
      environment_id = environment.environment_id;
      runtime_id = runtime.runtime_id;
      workspace = project.workspace;
      environment_name = environment.name;
    }

let evaluate_spend_guardrail ~(account : account) ~current_spend_cents =
  let* current_spend_cents =
    validate_non_negative_int ~field:"current_spend_cents" current_spend_cents
  in
  match account.spend_cap_cents with
  | None -> Error "account spend cap is required"
  | Some spend_cap_cents ->
    let status, behavior =
      if current_spend_cents >= spend_cap_cents then
        Cap_reached, Block_new_hosted_resources
      else
        match account.approval_threshold_cents with
        | Some threshold when current_spend_cents >= threshold ->
          Approval_required, Require_manual_approval
        | _ -> Within_cap, Continue_with_alert
    in
    Ok {
      account_id = account.account_id;
      current_spend_cents;
      spend_cap_cents;
      approval_threshold_cents = account.approval_threshold_cents;
      status;
      behavior;
    }

let make_cost_attribution
    ~attribution_id
    ~(environment : environment)
    ~(runtime : runtime_substrate)
    ~billing_period
    ~provider
    ~provider_resource_id
    ~resource_kind
    ~observed_cost_cents
    ~currency
    ?(metadata = [])
    () =
  let* attribution_id = validate_id ~field:"attribution_id" attribution_id in
  let* billing_period = validate_name ~field:"billing_period" billing_period in
  let* provider = validate_name ~field:"provider" provider in
  let* provider_resource_id =
    validate_name ~field:"provider_resource_id" provider_resource_id
  in
  let* resource_kind = validate_name ~field:"resource_kind" resource_kind in
  let* observed_cost_cents =
    validate_non_negative_int ~field:"observed_cost_cents" observed_cost_cents
  in
  let* currency = validate_currency currency in
  if environment.runtime_id <> runtime.runtime_id then
    Error "cost attribution runtime does not match environment"
  else if environment.account_id <> runtime.account_id then
    Error "cost attribution runtime does not belong to environment account"
  else
    Ok {
      attribution_id;
      account_id = environment.account_id;
      project_id = environment.project_id;
      environment_id = environment.environment_id;
      runtime_id = runtime.runtime_id;
      billing_period;
      provider;
      provider_resource_id;
      resource_kind;
      observed_cost_cents;
      currency;
      metadata;
    }

let make_early_cost_plus_billing_record
    ~(account : account)
    ~(environment : environment)
    ~billing_period
    ~provider_cost_cents
    ~markup_basis_points
    ~currency
    ~status =
  let* billing_period = validate_name ~field:"billing_period" billing_period in
  let* provider_cost_cents =
    validate_non_negative_int ~field:"provider_cost_cents" provider_cost_cents
  in
  let* markup_basis_points =
    validate_positive_int ~field:"markup_basis_points" markup_basis_points
  in
  let* currency = validate_currency currency in
  if environment.account_id <> account.account_id then
    Error "billing record environment does not belong to account"
  else
    let charge_amount_cents =
      (provider_cost_cents * markup_basis_points) / 10_000
    in
    Ok {
      account_id = account.account_id;
      environment_id = environment.environment_id;
      billing_period;
      provider_cost_cents;
      markup_basis_points;
      charge_amount_cents;
      currency;
      status;
    }

let secret_scope_to_json (s : secret_scope) =
  `Assoc [
    "account_id", `String s.account_id;
    "project_id", `String s.project_id;
    "environment_id", `String s.environment_id;
  ]

let release_target_to_json (t : release_target) =
  `Assoc [
    "account_id", `String t.account_id;
    "project_id", `String t.project_id;
    "environment_id", `String t.environment_id;
    "runtime_id", `String t.runtime_id;
    "workspace", `String t.workspace;
    "environment_name", `String t.environment_name;
  ]

let spend_guardrail_to_json (g : spend_guardrail) =
  `Assoc [
    "account_id", `String g.account_id;
    "current_spend_cents", `Int g.current_spend_cents;
    "spend_cap_cents", `Int g.spend_cap_cents;
    "approval_threshold_cents",
      (match g.approval_threshold_cents with
       | None -> `Null
       | Some cents -> `Int cents);
    "status", `String (cap_status_to_string g.status);
    "behavior", `String (cap_behavior_to_string g.behavior);
  ]

let cost_attribution_to_json (c : cost_attribution) =
  `Assoc [
    "attribution_id", `String c.attribution_id;
    "account_id", `String c.account_id;
    "project_id", `String c.project_id;
    "environment_id", `String c.environment_id;
    "runtime_id", `String c.runtime_id;
    "billing_period", `String c.billing_period;
    "provider", `String c.provider;
    "provider_resource_id", `String c.provider_resource_id;
    "resource_kind", `String c.resource_kind;
    "observed_cost_cents", `Int c.observed_cost_cents;
    "currency", `String c.currency;
    "metadata",
      `Assoc (List.map (fun (key, value) -> key, `String value) c.metadata);
  ]

let early_cost_plus_billing_record_to_json
    (r : early_cost_plus_billing_record) =
  `Assoc [
    "account_id", `String r.account_id;
    "environment_id", `String r.environment_id;
    "billing_period", `String r.billing_period;
    "provider_cost_cents", `Int r.provider_cost_cents;
    "markup_basis_points", `Int r.markup_basis_points;
    "charge_amount_cents", `Int r.charge_amount_cents;
    "currency", `String r.currency;
    "status", `String (billing_record_status_to_string r.status);
  ]
