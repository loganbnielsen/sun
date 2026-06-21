(** Sun_cli_command_request — typed CLI input records for [sun up] and [sun deploy].

    Each command's Cmdliner terms produce raw strings and option values.
    The [make] constructors below validate those raw values and return a typed
    request record (or an error) before any deployment logic runs.

    The command body pattern is:
    {[
      parse raw Cmdliner args
      → Sun_cli_command_request.{up,deploy}_request.make ...
      → call pipeline
    ]} *)

(** A validated request for [sun up]: build images and deploy to a local cluster. *)
type up_request = {
  filter_path          : string option;
  dry_run              : bool;
  image_tag            : string;
  confirm_group_change : bool;
}

(** A validated request for [sun deploy]: deploy pre-built images (CI/CD path). *)
type deploy_request = {
  filter_path          : string option;
  dry_run              : bool;
  emit_to              : string option;
  emit_plan_to         : string option;
  image_tag            : string;
  registry             : string;
  secret_backend       : Sun_cli_manifest.secret_backend;
  confirm_group_change : bool;
}

val make_up_request
  :  filter_path:string option
  -> dry_run:bool
  -> tag:string option
  -> confirm_group_change:bool
  -> git_sha:(unit -> string)
  -> (up_request, string) result
(** Validate raw Cmdliner values for [sun up] into an [up_request].
    [git_sha] is a thunk so callers can inject a real or stub implementation.
    Returns [Error msg] if validation fails. *)

val make_deploy_request
  :  filter_path:string option
  -> dry_run:bool
  -> emit_to:string option
  -> emit_plan_to:string option
  -> image_tag:string option
  -> registry:string option
  -> secret_backend:Sun_cli_manifest.secret_backend
  -> confirm_group_change:bool
  -> git_sha:(unit -> string)
  -> (deploy_request, string) result
(** Validate raw Cmdliner values for [sun deploy] into a [deploy_request].
    [git_sha] is a thunk so callers can inject a real or stub implementation.
    Returns [Error msg] if validation fails. *)
