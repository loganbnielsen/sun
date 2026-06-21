(** Change-set semantics for [sun deploy].

    A [change_set] is the single intermediate value between plan construction
    and cluster mutation.  It bundles the deployment plan, the rendered YAML
    artifacts, and the intended execution mode so that callers can inspect or
    serialize the full intended change before any side effect occurs.

    Lifecycle:
    {[
      plan            (* Sun_cli_deployment_plan.t *)
      → build         (* render all artifacts; no side effects *)
      → change_set
      → execute       (* side effects gated by mode *)
    ]} *)

(** A namespace-name pair of YAML documents for one service. *)
type rendered_artifact = {
  namespace_yaml : string;
  workload_yaml  : string;
  namespace      : string;
  name           : string;
  image          : string;
}

(** All rendered artifacts for a deployment plan — one entry per service. *)
type rendered_artifacts = rendered_artifact list

(** How the change set will be executed. *)
type execution_mode =
  | Dry_run
  | Emit_to of string
  | Apply

type change_set = {
  plan      : Sun_cli_deployment_plan.t;
  artifacts : rendered_artifacts;
  mode      : execution_mode;
}

val build :
  plan:Sun_cli_deployment_plan.t ->
  mode:execution_mode ->
  ?secret_backend:Sun_cli_manifest.secret_backend ->
  unit ->
  change_set
(** [build ~plan ~mode ?secret_backend ()] renders all artifacts from [plan]
    and returns a [change_set].  No executor side effects are performed. *)

val execute :
  change_set ->
  Sun_cli_executor.result list
(** [execute cs] applies the change set according to [cs.mode]:
    - [Dry_run] — prints rendered YAML to stdout; no kubectl called.
    - [Emit_to dir] — writes YAML files under [dir]; no kubectl called.
    - [Apply] — applies manifests to the current kube context via kubectl.

    Returns one [Sun_cli_executor.result] per service in plan order. *)
