(** Read-only release inspection and diagnostics models.

    This module defines Sun-facing release facts for hosted and customer-cloud
    inspection surfaces. It intentionally does not expose Argo CD or Kubernetes
    write APIs. *)

type rollout_status =
  | Rollout_not_started
  | Rollout_progressing
  | Rollout_succeeded
  | Rollout_failed
  | Rollout_unknown

type health_status =
  | Health_unknown
  | Health_healthy
  | Health_degraded
  | Health_unhealthy

type deployment_plan_summary = {
  workspace       : string;
  environment     : string;
  mode            : string;
  image_tag       : string;
  service_count   : int;
  topic_count     : int;
  migration_count : int;
}

type image_ref = {
  service_name : string;
  image        : string;
}

type affected_service = {
  service_name   : string;
  namespace      : string;
  primitive      : string;
  image          : string;
  rollout_status : rollout_status;
  health_status  : health_status;
  error_reason   : string option;
}

type release_summary = {
  release_id       : string;
  environment_id   : string;
  environment_name : string;
  status           : string;
  plan             : deployment_plan_summary;
  image_refs       : image_ref list;
  services         : affected_service list;
}

type rendered_manifest = {
  name      : string;
  namespace : string;
  kind      : string;
  yaml      : string;
}

type diagnostic_event = {
  source   : string;
  reason   : string;
  message  : string;
  severity : string;
}

type diagnostics = {
  release               : release_summary;
  rendered_manifests    : rendered_manifest list;
  reconciliation_events : diagnostic_event list;
  rollout_resources     : string list;
  kubernetes_events     : diagnostic_event list;
  raw_failure_details   : string option;
}

val rollout_status_to_string : rollout_status -> string
val health_status_to_string : health_status -> string

val deployment_plan_summary :
  Sun_cli_deployment_plan.t -> deployment_plan_summary

val affected_service :
  ?rollout_status:rollout_status ->
  ?health_status:health_status ->
  ?error_reason:string ->
  image:string ->
  Sun_cli_deployment_plan.service_spec ->
  affected_service

val release_summary :
  release_id:string ->
  environment_id:string ->
  environment_name:string ->
  status:string ->
  plan:Sun_cli_deployment_plan.t ->
  image_refs:image_ref list ->
  services:affected_service list ->
  release_summary

val rendered_manifests_of_plan :
  Sun_cli_deployment_plan.t -> rendered_manifest list
(** Render inspectable manifest facts from the deployment plan. The YAML is a
    read-only diagnostic artifact. *)

val diagnostics :
  ?rendered_manifests:rendered_manifest list ->
  ?reconciliation_events:diagnostic_event list ->
  ?rollout_resources:string list ->
  ?kubernetes_events:diagnostic_event list ->
  ?raw_failure_details:string ->
  release_summary ->
  diagnostics

val deployment_plan_summary_to_json : deployment_plan_summary -> Yojson.Safe.t
val image_ref_to_json : image_ref -> Yojson.Safe.t
val affected_service_to_json : affected_service -> Yojson.Safe.t
val release_summary_to_json : release_summary -> Yojson.Safe.t
val rendered_manifest_to_json : rendered_manifest -> Yojson.Safe.t
val diagnostic_event_to_json : diagnostic_event -> Yojson.Safe.t
val diagnostics_to_json : diagnostics -> Yojson.Safe.t
