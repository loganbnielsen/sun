(** Experimental Sun-hosted executor boundary.

    This module is a spike for handing an already-built deployment plan to a
    future Sun-hosted control plane. It intentionally performs no network I/O,
    auth, persistence, provisioning, billing, or managed-cluster work. *)

type image_ref = {
  service_name : string;
  image        : string;
}
(** Immutable image artifact supplied by customer CI for one service. *)

type release_status =
  | Mock_submitted

type service_summary = {
  service_name : string;
  namespace    : string;
  primitive    : Sun_cli_deployment_plan.primitive;
  image        : string;
  default_url  : string option;
  (** Sun-managed default URL; [Some] for [-svc] workloads, [None] otherwise. *)
}

type release = {
  release_id       : string;
  environment_id   : Sun_cli_hosted_model.environment_id;
  environment_name : string;
  status           : release_status;
  services         : service_summary list;
  inspection       : Sun_cli_release_inspection.release_summary;
}
(** Release-like response shape returned by the mock submission path. *)

type request = {
  target          : Sun_cli_hosted_model.release_target;
  plan            : Sun_cli_deployment_plan.t;
  serialized_plan : Yojson.Safe.t;
  image_refs      : image_ref list;
}
(** Experimental hosted submission request.

    [serialized_plan] is the handoff artifact. [plan] is kept only so this spike
    can validate and summarize the artifact without freezing a JSON parser or
    hosted control-plane API. *)

val image_refs_of_plan : Sun_cli_deployment_plan.t -> image_ref list
(** Extract image refs from the deployment plan's service specs. *)

val submit_mock : request -> (release, string) result
(** Validate and submit a request to the mock hosted path. *)

val release_status_to_string : release_status -> string
val release_to_json : release -> Yojson.Safe.t
