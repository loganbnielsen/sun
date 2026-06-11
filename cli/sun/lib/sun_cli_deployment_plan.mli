type deployment_mode = Local | Customer_cloud | Sun_hosted

type env_config = {
  name           : string;
  mode           : deployment_mode;
  registry       : string;
  image_tag      : string;
  region         : string option;
  base_domain    : string option;
  secret_backend : string;
}

type primitive = Svc | Worker | Fn

type service_spec = {
  domain                : string;
  source_name           : string;
  k8s_name              : string;
  namespace             : string;
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

val to_json : t -> Yojson.Safe.t
(** Serialize a deployment plan to JSON (experimental format — schema not frozen).
    Config values are included; secret keys are included but secret values are omitted. *)

val pp_summary : Format.formatter -> t -> unit
(** Print a human-readable deployment plan summary. *)

val k8s_name_of : string -> string
(** Convert a service source name to a k8s-safe name: underscores become hyphens. *)

val namespace_of : workspace:string -> domain:string -> string
(** [namespace_of ~workspace ~domain] returns ["<workspace>-<domain>"]. *)

val image_ref : registry:string -> workspace:string -> k8s_name:string -> tag:string -> string
(** [image_ref ~registry ~workspace ~k8s_name ~tag] returns
    ["<registry>/<workspace>/<k8s_name>:<tag>"]. *)

val of_services :
  workspace:string ->
  env:env_config ->
  Sun_cli_manifest.service list ->
  t
(** Build a deployment plan from a discovered service list and an environment config. *)

val render_spec :
  ?image:string ->
  ?secret_backend:Sun_cli_manifest.secret_backend ->
  service_spec ->
  string * string
(** Render a [(namespace_yaml, workload_yaml)] pair from a resolved [service_spec].
    All deployment identity fields (namespace, k8s name, image, primitive,
    config, secrets, schedule, replicas, cpu, memory) come from the spec.
    Pass [~image] to override [spec.image] — used by [sun up] where the
    dry-run display image ([localhost:5000]) differs from the cluster image.
    Pass [~secret_backend] to control how secret manifests are emitted:
    - [Kubernetes_live] (default): emit a Secret with real values (sun up / direct deploy);
    - [Kubernetes_placeholder]: emit a redacted Secret with empty stringData (GitOps);
    - [External_secrets _]: emit an ExternalSecret CRD for the External Secrets Operator. *)
