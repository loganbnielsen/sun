(** Experimental hosted account/environment model.

    This module defines only the ownership and identity boundary needed by the
    hosted executor spike. It intentionally does not implement auth, persistence,
    provisioning, billing-provider integration, or RBAC. *)

module Account_id : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
end

module Project_id : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
end

module Environment_id : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
end

module Runtime_id : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
end

module Attribution_id : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
end

type account_id = Account_id.t
type project_id = Project_id.t
type environment_id = Environment_id.t
type runtime_id = Runtime_id.t
type attribution_id = Attribution_id.t

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

val make_account :
  account_id:string ->
  display_name:string ->
  billing_state:billing_state ->
  ?spend_cap_cents:int ->
  ?approval_threshold_cents:int ->
  unit ->
  (account, string) result

val make_project :
  project_id:string ->
  account:account ->
  workspace:string ->
  display_name:string ->
  (project, string) result

val make_runtime :
  runtime_id:string ->
  account:account ->
  ?region:string ->
  ?base_domain:string ->
  unit ->
  (runtime_substrate, string) result

val make_environment :
  environment_id:string ->
  account:account ->
  project:project ->
  runtime:runtime_substrate ->
  name:string ->
  (environment, string) result

val secret_scope :
  account:account ->
  project:project ->
  environment:environment ->
  (secret_scope, string) result

val release_target :
  account:account ->
  project:project ->
  environment:environment ->
  runtime:runtime_substrate ->
  plan:Sun_cli_deployment_plan.t ->
  (release_target, string) result
(** [release_target] checks that hosted ownership matches the deployment plan:
    project workspace must equal [plan.workspace], environment name must equal
    [plan.environment.name], and all account/project/runtime links must align. *)

val evaluate_spend_guardrail :
  account:account ->
  current_spend_cents:int ->
  (spend_guardrail, string) result

val make_cost_attribution :
  attribution_id:string ->
  environment:environment ->
  runtime:runtime_substrate ->
  billing_period:string ->
  provider:string ->
  provider_resource_id:string ->
  resource_kind:string ->
  observed_cost_cents:int ->
  currency:string ->
  ?metadata:(string * string) list ->
  unit ->
  (cost_attribution, string) result

val make_early_cost_plus_billing_record :
  account:account ->
  environment:environment ->
  billing_period:string ->
  provider_cost_cents:int ->
  markup_basis_points:int ->
  currency:string ->
  status:billing_record_status ->
  (early_cost_plus_billing_record, string) result

val release_target_to_json : release_target -> Yojson.Safe.t
val secret_scope_to_json : secret_scope -> Yojson.Safe.t
val spend_guardrail_to_json : spend_guardrail -> Yojson.Safe.t
val cost_attribution_to_json : cost_attribution -> Yojson.Safe.t
val early_cost_plus_billing_record_to_json :
  early_cost_plus_billing_record -> Yojson.Safe.t

val billing_state_to_string : billing_state -> string
val tenancy_to_string : tenancy -> string
val runtime_kind_to_string : runtime_kind -> string
val cap_behavior_to_string : cap_behavior -> string
val cap_status_to_string : cap_status -> string
val billing_record_status_to_string : billing_record_status -> string
val account_id_to_string : account_id -> string
val project_id_to_string : project_id -> string
val environment_id_to_string : environment_id -> string
val runtime_id_to_string : runtime_id -> string
val attribution_id_to_string : attribution_id -> string
