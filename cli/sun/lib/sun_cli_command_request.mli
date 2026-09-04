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
  target                : string;
  (** Deployment target path, [<env>/<provider>/<region>] — resolved via
      [Sun_cli_config.load_for_target]. Required: [sun deploy]'s positional
      target argument, matching [sun plan]'s existing convention. *)
  filter_path           : string option;
  dry_run               : bool;
  emit_to               : string option;
  emit_plan_to          : string option;
  image_tag             : string;
  registry              : string option;
  (** Raw [--registry] value, unresolved. [None] means "use the target
      file's registry, or fail if it has none" — that resolution (no
      hardcoded local-registry fallback; [sun deploy] is always the
      customer-cluster path) happens in [cmd_deploy.ml] once the target
      loads, not here, since this constructor never touches
      [Sun_cli_config]. *)
  secret_backend        : Sun_cli_manifest.secret_backend;
  confirm_group_change  : bool;
  loki_push_url         : string option;
  (** Raw [--loki-push-url] value (OBS-037). [None] means "resolve the push
      URL from the target's observability backend" -- see
      [Sun_cli_deploy_event.resolve_push_url]. Only meaningful for a real
      apply (not [--dry-run]/[--emit-to], which push no deploy event at
      all). *)
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
  :  target:string
  -> filter_path:string option
  -> dry_run:bool
  -> emit_to:string option
  -> emit_plan_to:string option
  -> image_tag:string option
  -> registry:string option
  -> secret_backend:Sun_cli_manifest.secret_backend
  -> confirm_group_change:bool
  -> loki_push_url:string option
  -> git_sha:(unit -> string)
  -> (deploy_request, string) result
(** Validate raw Cmdliner values for [sun deploy] into a [deploy_request].
    [git_sha] is a thunk so callers can inject a real or stub implementation.
    Returns [Error msg] if validation fails — including [target] being
    empty (cmdliner's [required] should already prevent this, but this
    constructor doesn't assume its caller enforced that). *)
