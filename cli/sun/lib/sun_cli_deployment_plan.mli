type deployment_mode = Local | Customer_cloud | Sun_hosted

type env_config = {
  name           : string;
  mode           : deployment_mode;
  registry       : string;
  image_tag      : string;
  region         : string option;
  base_domain    : string option;
  secret_backend : Sun_cli_manifest.secret_backend;
}

type primitive = Svc | Worker | Fn

type effective_rollout_strategy =
  | Effective_canary
  | Effective_blue_green
  | Effective_recreate
  | Effective_rolling_update

type k8s_name = Sun_cli_kubernetes_name.k8s_name
type namespace = Sun_cli_kubernetes_name.namespace

type service_spec = {
  domain                : string;
  source_name           : string;
  k8s_name              : k8s_name;
  namespace             : namespace;
  primitive             : primitive;
  source_dir            : string;
  image                 : string;
  config                : (string * string) list;
  secrets               : (string * string) list;
  schedule              : string option;
  replicas              : int;
  cpu                   : string;
  memory                : string;
  rollout_strategy      : Sun_cli_toml.rollout_strategy option;
  ingress_host          : string option;
  ingress_path          : string option;
  extra_labels          : (string * string) list;
  progressive_delivery  : Sun_cli_toml.progressive_delivery option;
}

type t = {
  workspace        : string;
  environment      : env_config;
  services         : service_spec list;
  topics           : string list;
  migrations       : string list;
  schema_subjects  : string list;
  consumer_groups  : string list;
}

type plan_error =
  | Toml_error of Sun_cli_toml.parse_error
  | Invalid_kubernetes_name of { field : string; value : string; message : string }

val discover_topics : unit -> string list
(** Scan [events/*.ml] in the current directory for ['let topic_name = "..."']
    declarations and return the topic names, sorted and deduplicated.
    Returns [[]] when the [events/] directory does not exist. *)

val discover_migrations : unit -> string list
(** Scan [db/migrations/*.sql] in the current directory and return filenames
    sorted by name.  Returns [[]] when [db/migrations/] does not exist. *)

val discover_schema_subjects : unit -> string list
(** Scan [events/<domain>/*.ml] for event contract files and derive schema
    subject names as ["<domain>.<EventName>"].  Top-level [events/<event>.ml]
    files are returned without a domain prefix.  Returns a sorted,
    deduplicated list.  Returns [[]] when the [events/] directory does not exist. *)

val derive_consumer_groups : string -> service_spec list -> string list
(** [derive_consumer_groups workspace services] returns a sorted, deduplicated
    list of consumer group identifiers for all [Worker] entries in [services].
    Convention: ["<workspace>.<domain>.<worker_name>"]. *)

val effective_rollout_strategy : service_spec -> effective_rollout_strategy
(** Resolve the deployment strategy that applies after progressive delivery
    settings have taken precedence over Deployment rollout settings. *)

val effective_rollout_strategy_to_string : effective_rollout_strategy -> string
(** Render an [effective_rollout_strategy] for deployment plan JSON and summaries. *)

val to_json : t -> Yojson.Safe.t
(** Serialize a deployment plan to JSON (experimental format — schema not frozen).
    Config values are included; secret keys are included but secret values are omitted. *)

val pp_summary : Format.formatter -> t -> unit
(** Print a human-readable deployment plan summary. *)

val plan_error_to_string : plan_error -> string
(** Render a deployment-plan construction error for CLI output. *)

val k8s_name_of : string -> string
(** Legacy normalization helper: lowercase ASCII and convert underscores to hyphens.
    Use [k8s_name_result] when constructing deployment artifacts. *)

val k8s_name_result : string -> (k8s_name, plan_error) result
(** Normalize and validate a service source name as a Kubernetes DNS label. *)

val k8s_name_to_string : k8s_name -> string

val namespace_of : workspace:string -> domain:string -> namespace
(** [namespace_of ~workspace ~domain] returns a validated namespace for
    ["<workspace>-<domain>"]. Raises [Failure] if validation fails. *)

val namespace_result : workspace:string -> domain:string -> (namespace, plan_error) result
(** Normalize workspace/domain into a namespace and validate it as a Kubernetes DNS label. *)

val namespace_to_string : namespace -> string

val image_ref : registry:string -> workspace:string -> k8s_name:k8s_name -> tag:string -> string
(** [image_ref ~registry ~workspace ~k8s_name ~tag] returns
    ["<registry>/<workspace>/<k8s_name>:<tag>"]. *)

val of_services :
  workspace:string ->
  env:env_config ->
  Sun_cli_manifest.service list ->
  t
(** Compatibility wrapper around [of_services_result]. Raises [Failure] if a
    service [sun.toml] cannot be parsed or validated. *)

val of_services_result :
  workspace:string ->
  env:env_config ->
  Sun_cli_manifest.service list ->
  (t, plan_error) result
(** Build a deployment plan from a discovered service list and an environment
    config. Returns a typed error when a Kubernetes artifact name is invalid or
    a service [sun.toml] cannot be parsed or validated. *)

val render_spec :
  ?image:string ->
  ?secret_backend:Sun_cli_manifest.secret_backend ->
  service_spec ->
  (string * string, string) result
(** Render a [(namespace_yaml, workload_yaml)] pair from a resolved [service_spec].
    Returns [Ok (ns_yaml, workload_yaml)] on success.
    Returns [Error msg] when [secret_backend = Kubernetes_live] and one or more
    user-declared secret env vars (from [spec.secrets]) are absent from the
    process environment.
    All deployment identity fields (namespace, k8s name, image, primitive,
    config, secrets, schedule, replicas, cpu, memory) come from the spec.
    Pass [~image] to override [spec.image] — used by [sun up] where the
    dry-run display image ([localhost:5000]) differs from the cluster image.
    Pass [~secret_backend] to control how secret manifests are emitted:
    - [Kubernetes_live] (default): emit a Secret with values read from the environment
      (sun up / direct deploy); fails if any user-declared secret key is unset;
    - [Kubernetes_placeholder]: emit a redacted Secret with empty stringData (GitOps);
    - [External_secrets _]: emit an ExternalSecret CRD for the External Secrets Operator. *)
