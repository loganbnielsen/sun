(** Sun_cli_env_target — typed boundary between workspace intent and
    environment-owned substrate inputs.

    A deployment target captures what is provided by the target environment
    (registry, cluster, secret references, observability endpoints) rather
    than by the application workspace being deployed.

    Callers should build a value using one of the constructor helpers
    ([local_defaults] or [customer_cloud_defaults]) and pass it through to
    [Sun_cli_deployment_plan.of_services] via [to_env_config]. *)

(** The four supported deployment modes.

    - [Local_k3d]           — local k3d cluster with a registry container
    - [Customer_k8s_direct] — customer cluster, manifests applied via kubectl
    - [Customer_k8s_gitops] — customer cluster, manifests written to a GitOps dir
    - [Sun_hosted]          — reserved placeholder; not yet implemented *)
type target =
  | Local_k3d
  | Customer_k8s_direct
  | Customer_k8s_gitops
  | Sun_hosted

(** All values that come from the target environment rather than the workspace. *)
type t = {
  target              : target;
  registry            : string;
  image_tag           : string;
  region              : string option;
  base_domain         : string option;
  kafka_brokers           : string option;
  postgres_secret_name    : string option;
  loki_url                : string option;
  pushgateway_url         : string option;
}

(** {2 Constructors} *)

val local_defaults : image_tag:string -> t
(** [local_defaults ~image_tag] returns a [Local_k3d] target with the
    registry constants used by [sun up] (push: localhost:5000, pull:
    sun-registry:5000).  Callers should always go through this function
    rather than hard-coding registry strings in command modules. *)

val customer_cloud_defaults
  :  registry:string
  -> image_tag:string
  -> ?region:string option
  -> ?base_domain:string option
  -> ?kafka_brokers:string option
  -> ?postgres_secret_name:string option
  -> ?loki_url:string option
  -> ?pushgateway_url:string option
  -> emit_to:string option
  -> unit
  -> t
(** [customer_cloud_defaults ~registry ~image_tag ~emit_to ()] builds the
    environment target for a customer-cloud deployment.  The [target] variant
    is [Customer_k8s_gitops] when [emit_to] is [Some _], and
    [Customer_k8s_direct] otherwise.  All optional infrastructure endpoints
    default to [None] (not required for direct-apply mode). *)

(** {2 Accessors} *)

val target              : t -> target
val registry            : t -> string
val image_tag           : t -> string
val region              : t -> string option
val base_domain         : t -> string option
val kafka_brokers       : t -> string option
val postgres_secret_name : t -> string option
val loki_url            : t -> string option
val pushgateway_url     : t -> string option

(** {2 Validation} *)

val validate : t -> (unit, string) result
(** [validate t] checks that the env target is self-consistent.

    Rules:
    - [Local_k3d]  — always [Ok ()]; the local cluster is set up by [sun dev up].
    - [Sun_hosted] — always [Ok ()]; the hosted control plane handles substrate.
    - [Customer_k8s_direct] / [Customer_k8s_gitops] — [registry] must be
      non-empty, because there is no implicit registry for customer clusters.

    Returns [Error msg] with a human-readable message on failure. *)

(** {2 Conversion} *)

val to_env_config : name:string -> t -> Sun_cli_deployment_plan.env_config
(** [to_env_config ~name t] converts an env target into the
    [Sun_cli_deployment_plan.env_config] expected by
    [Sun_cli_deployment_plan.of_services].  [name] is the logical environment
    name (e.g., ["local"], ["production"]). *)
