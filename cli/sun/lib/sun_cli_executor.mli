(** Deployment executors — plan-in, side-effect-out.

    Each executor renders a [service_spec] to YAML via
    [Sun_cli_deployment_plan.render_spec] and then dispatches to the
    appropriate apply or emit primitive.  Command logic selects the
    executor; the executor owns the dispatch. *)

type result = {
  namespace : string;
  name      : string;
  image     : string;
}
(** Summary of what was applied or emitted for a single service. *)

val local : dry_run:bool -> Sun_cli_deployment_plan.service_spec -> result
(** Apply to the local k3d cluster (current kube context).
    In dry-run mode the rendered YAML is printed to stdout rather than
    applied.  Pass [~image] indirectly via the spec; callers that need to
    show a push-registry image should override [spec.image] before calling. *)

val direct : dry_run:bool -> Sun_cli_deployment_plan.service_spec -> result
(** Apply to the current kube context (CI/production direct-k8s mode).
    Identical to [local] at the executor level — both apply to whatever
    context [kubectl] is pointing at.  The distinction is purely in how the
    surrounding command constructs the env target and plan. *)

val gitops : dir:string -> Sun_cli_deployment_plan.service_spec -> result
(** Write manifests to [dir/<namespace>-<name>.yaml] for GitOps workflows.
    The directory is created if it does not already exist.
    Returns [result] with [namespace] and [name] from the spec and
    [image] from the spec. *)
