let is_id_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true
  | _ -> false

let validate_id ~field value =
  let value = String.trim value in
  if value = "" then Error (Printf.sprintf "%s must not be empty" field)
  else if not (String.for_all is_id_char value) then
    Error (Printf.sprintf "%s %S contains unsupported characters" field value)
  else Ok value

module Make_id (Name : sig val field : string end) = struct
  type t = string

  let of_string value = validate_id ~field:Name.field value
  let to_string t = t
end

module Account_id = Make_id (struct let field = "account_id" end)
module Project_id = Make_id (struct let field = "project_id" end)
module Environment_id = Make_id (struct let field = "environment_id" end)
module Runtime_id = Make_id (struct let field = "runtime_id" end)
module Attribution_id = Make_id (struct let field = "attribution_id" end)

let is_digit = function
  | '0' .. '9' -> true
  | _ -> false

let validate_billing_period value =
  let value = String.trim value in
  if String.length value <> 7 then
    Error "billing_period must use YYYY-MM format"
  else if value.[4] <> '-' then
    Error "billing_period must use YYYY-MM format"
  else if not (String.for_all is_digit (String.sub value 0 4)) then
    Error "billing_period must use YYYY-MM format"
  else if not (String.for_all is_digit (String.sub value 5 2)) then
    Error "billing_period must use YYYY-MM format"
  else
    let month = int_of_string (String.sub value 5 2) in
    if month < 1 || month > 12 then
      Error "billing_period month must be between 01 and 12"
    else Ok value

let validate_currency value =
  let value = String.trim value in
  if String.length value <> 3 then Error "currency must be a 3-letter code"
  else if not (String.for_all (function 'A' .. 'Z' -> true | _ -> false) value) then
    Error "currency must be uppercase ASCII"
  else Ok value

module Billing_period = struct
  type t = string

  let of_string = validate_billing_period
  let to_string t = t
end

module Cost_provider = Make_id (struct let field = "provider" end)
module Cost_resource_kind = Make_id (struct let field = "resource_kind" end)

module Currency = struct
  type t = string

  let of_string = validate_currency
  let to_string t = t
end

type account_id = Account_id.t
type project_id = Project_id.t
type environment_id = Environment_id.t
type runtime_id = Runtime_id.t
type attribution_id = Attribution_id.t
type billing_period = Billing_period.t
type cost_provider = Cost_provider.t
type cost_resource_kind = Cost_resource_kind.t
type currency = Currency.t

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
  billing_period        : billing_period;
  provider              : cost_provider;
  provider_resource_id  : string;
  resource_kind         : cost_resource_kind;
  observed_cost_cents   : int;
  currency              : currency;
  metadata              : (string * string) list;
}

type early_cost_plus_billing_record = {
  account_id            : account_id;
  environment_id        : environment_id;
  billing_period        : billing_period;
  provider_cost_cents   : int;
  markup_basis_points   : int;
  charge_amount_cents   : int;
  currency              : currency;
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

let account_id_to_string = Account_id.to_string
let project_id_to_string = Project_id.to_string
let environment_id_to_string = Environment_id.to_string
let runtime_id_to_string = Runtime_id.to_string
let attribution_id_to_string = Attribution_id.to_string
let billing_period_to_string = Billing_period.to_string
let cost_provider_to_string = Cost_provider.to_string
let cost_resource_kind_to_string = Cost_resource_kind.to_string
let currency_to_string = Currency.to_string

let validate_name ~field value =
  let value = String.trim value in
  if value = "" then Error (Printf.sprintf "%s must not be empty" field)
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
  let* account_id = Account_id.of_string account_id in
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
  let* project_id = Project_id.of_string project_id in
  let* workspace = validate_id ~field:"workspace" workspace in
  let* display_name = validate_name ~field:"project display_name" display_name in
  Ok { project_id; account_id = account.account_id; workspace; display_name }

let make_runtime ~runtime_id ~(account : account) ?region ?base_domain () =
  let* runtime_id = Runtime_id.of_string runtime_id in
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
  let* environment_id = Environment_id.of_string environment_id in
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
  let* attribution_id = Attribution_id.of_string attribution_id in
  let* billing_period = Billing_period.of_string billing_period in
  let* provider = Cost_provider.of_string provider in
  let* provider_resource_id =
    validate_name ~field:"provider_resource_id" provider_resource_id
  in
  let* resource_kind = Cost_resource_kind.of_string resource_kind in
  let* observed_cost_cents =
    validate_non_negative_int ~field:"observed_cost_cents" observed_cost_cents
  in
  let* currency = Currency.of_string currency in
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
  let* billing_period = Billing_period.of_string billing_period in
  let* provider_cost_cents =
    validate_non_negative_int ~field:"provider_cost_cents" provider_cost_cents
  in
  let* markup_basis_points =
    validate_positive_int ~field:"markup_basis_points" markup_basis_points
  in
  let* currency = Currency.of_string currency in
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
    "account_id", `String (Account_id.to_string s.account_id);
    "project_id", `String (Project_id.to_string s.project_id);
    "environment_id", `String (Environment_id.to_string s.environment_id);
  ]

let release_target_to_json (t : release_target) =
  `Assoc [
    "account_id", `String (Account_id.to_string t.account_id);
    "project_id", `String (Project_id.to_string t.project_id);
    "environment_id", `String (Environment_id.to_string t.environment_id);
    "runtime_id", `String (Runtime_id.to_string t.runtime_id);
    "workspace", `String t.workspace;
    "environment_name", `String t.environment_name;
  ]

let spend_guardrail_to_json (g : spend_guardrail) =
  `Assoc [
    "account_id", `String (Account_id.to_string g.account_id);
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
    "attribution_id", `String (Attribution_id.to_string c.attribution_id);
    "account_id", `String (Account_id.to_string c.account_id);
    "project_id", `String (Project_id.to_string c.project_id);
    "environment_id", `String (Environment_id.to_string c.environment_id);
    "runtime_id", `String (Runtime_id.to_string c.runtime_id);
    "billing_period", `String (Billing_period.to_string c.billing_period);
    "provider", `String (Cost_provider.to_string c.provider);
    "provider_resource_id", `String c.provider_resource_id;
    "resource_kind", `String (Cost_resource_kind.to_string c.resource_kind);
    "observed_cost_cents", `Int c.observed_cost_cents;
    "currency", `String (Currency.to_string c.currency);
    "metadata",
      `Assoc (List.map (fun (key, value) -> key, `String value) c.metadata);
  ]

let early_cost_plus_billing_record_to_json
    (r : early_cost_plus_billing_record) =
  `Assoc [
    "account_id", `String (Account_id.to_string r.account_id);
    "environment_id", `String (Environment_id.to_string r.environment_id);
    "billing_period", `String (Billing_period.to_string r.billing_period);
    "provider_cost_cents", `Int r.provider_cost_cents;
    "markup_basis_points", `Int r.markup_basis_points;
    "charge_amount_cents", `Int r.charge_amount_cents;
    "currency", `String (Currency.to_string r.currency);
    "status", `String (billing_record_status_to_string r.status);
  ]
