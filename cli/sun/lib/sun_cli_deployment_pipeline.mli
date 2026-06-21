(** Sun_cli_deployment_pipeline — explicit typed phases for the deployment compiler.

    The deployment pipeline transforms CLI input through five phases:

      request -> resolved_environment -> plan -> artifacts -> execution_result

    Each phase is a distinct type.  Callers can inspect or test any intermediate
    phase without needing to drive the full pipeline to completion.  [cmd_up] and
    [cmd_deploy] share the [resolve_environment] and [build_plan] phases; only the
    executor dispatch differs between them. *)

(** {1 Phase 1 — Request}

    Raw inputs supplied by the CLI layer.  No I/O has been performed yet. *)

type request = {
  workspace            : string;
  image_tag            : string;
  filter_path          : string option;
  emit_to              : string option;
  secret_backend       : Sun_cli_manifest.secret_backend;
  confirm_group_change : bool;
  dry_run              : bool;
}
(** Inputs that the CLI caller has already resolved (workspace name, git SHA,
    flags).  Both [cmd_up] and [cmd_deploy] build one of these before handing
    off to the pipeline. *)

(** {1 Phase 2 — Resolved environment}

    Environment target validated and projected into a deployment [env_config]. *)

type resolved_environment = {
  env_target : Sun_cli_env_target.t;
  env_config : Sun_cli_deployment_plan.env_config;
}
(** The environment target after [Sun_cli_env_target.validate] has succeeded and
    [Sun_cli_env_target.to_env_config] has been applied.  [env_config] is the
    value that will be passed to [Sun_cli_deployment_plan.of_services_result]. *)

type pipeline_error =
  | Env_validation_error of string
  | No_services_found
  | Plan_error of Sun_cli_deployment_plan.plan_error
  | Consumer_group_change of { removed : string list }
(** Typed failure modes that can arise before any executor is called. *)

val pipeline_error_to_string : pipeline_error -> string

(** {2 Constructor helpers for resolved_environment} *)

val resolve_local : image_tag:string -> workspace:string -> resolved_environment
(** Build the resolved environment for a [sun up] (local k3d) deployment.
    The registry is always [sun-registry:5000]; [image_tag] is the short git SHA
    or a caller-supplied override. *)

val resolve_customer_cloud :
  registry:string ->
  image_tag:string ->
  workspace:string ->
  emit_to:string option ->
  secret_backend:Sun_cli_manifest.secret_backend ->
  (resolved_environment, pipeline_error) result
(** Build and validate the resolved environment for a [sun deploy] (customer
    cluster) deployment.  Returns [Error (Env_validation_error msg)] when the
    registry is empty for a customer target. *)

(** {1 Phase 3 — Plan}

    A fully constructed deployment plan. *)

val build_plan :
  request ->
  resolved_environment ->
  Sun_cli_manifest.service list ->
  (Sun_cli_deployment_plan.t, pipeline_error) result
(** [build_plan req env services] constructs a [Sun_cli_deployment_plan.t] and
    checks the consumer-group change guard.

    Errors:
    - [Plan_error _] — Kubernetes name or TOML parse failure.
    - [Consumer_group_change _] — removed consumer groups detected and
      [req.confirm_group_change] is [false].  The guard is skipped in dry-run
      mode and when [req.emit_to] is [Some _] (GitOps path does not own cluster
      state). *)

(** {1 Phase 4 — Artifacts}

    Per-service rendered YAML, ready to be applied or written to disk. *)

type artifact = {
  spec         : Sun_cli_deployment_plan.service_spec;
  ns_yaml      : string;
  workload_yaml : string;
}
(** Rendered YAML for one service. [spec] is the source plan entry so callers
    can read [spec.k8s_name], [spec.namespace], [spec.image], etc. without
    re-parsing the YAML. *)

val render_artifacts :
  ?image_override:(Sun_cli_deployment_plan.service_spec -> string) ->
  secret_backend:Sun_cli_manifest.secret_backend ->
  Sun_cli_deployment_plan.t ->
  artifact list
(** Render all services in [plan] to [artifact] values.  The optional
    [~image_override] lets [cmd_up] substitute the push-registry image for
    dry-run display without mutating the plan. *)

(** {1 Phase 5 — Execution result} *)

type execution_result = {
  namespace : string;
  name      : string;
  image     : string;
}
(** The outcome of applying or emitting a single service artifact. *)

val apply_artifact : dry_run:bool -> artifact -> execution_result
(** Apply [artifact] to the current kubectl context.  In dry-run mode, the YAML
    is printed to stdout instead of being applied. *)

val emit_artifact : dir:string -> artifact -> execution_result
(** Write [artifact] YAML to [dir/<namespace>-<name>.yaml].  The directory is
    created if it does not exist. *)
