type secret_backend =
  | Kubernetes_live         (** Emit a Kubernetes Secret with real values (live deploy / sun up). *)
  | Kubernetes_placeholder  (** Emit a redacted Kubernetes Secret with empty stringData (GitOps). *)
  | External_secrets of {
      store_ref        : string;
      store_kind       : string;
      key_prefix       : string;
      refresh_interval : string;
    }

type primitive = Svc | Worker | Fn

type service = {
  domain : string;
  name   : string;
  prim   : primitive;
  dir    : string;
}

val prim_of_suffix  : string -> primitive option
val prim_label      : primitive -> string
val discover_services : filter_path:string option -> service list

(** [scan_binding ~is_let binding content] scans [content] for OCaml bindings
    of the form [let <binding> = "<value>"] (when [is_let] is [true]) or
    [<binding> = "<value>"] (when [is_let] is [false]) with flexible whitespace.
    Skips blank lines and lines starting with '('. Returns all matched values. *)
val scan_binding : is_let:bool -> string -> string -> string list

val extract_schedule  : dir:string -> name:string -> string

val default_cluster_env : (string * string) list
val default_secrets     : (string * string) list
val runtime_secret_name : string
val config_hash : (string * string) list -> string

(** Low-level YAML document builders used by [render] and [render_spec]. *)
val namespace_doc      : string -> string
val service_account_doc : string -> string -> string
val configmap_doc      : ?extra_env:(string * string) list -> string -> string -> string
val secret_doc         : ?base_secrets:(string * string) list -> ?extra_secrets:(string * string) list -> ?redact:bool -> string -> string -> string
val external_secret_doc : store_ref:string -> store_kind:string -> key_prefix:string -> refresh_interval:string -> secret_keys:string list -> string -> string -> string
val deployment_doc     : ?rollout_strategy:Sun_cli_toml.rollout_strategy -> ?extra_labels:(string * string) list -> ?secret_keys:string list -> ?config_hash:string -> ports:bool -> probes:bool -> replicas:int -> cpu:string -> memory:string -> string -> string -> string -> string

(** [rollout_doc] renders an Argo Rollout resource instead of a Deployment.
    Requires Argo Rollouts installed in the cluster.
    [pd] must be [Canary _] or [Blue_green]. *)
val rollout_doc : ?extra_labels:(string * string) list -> ?secret_keys:string list -> ?config_hash:string -> ports:bool -> probes:bool -> replicas:int -> cpu:string -> memory:string -> string -> string -> string -> Sun_cli_toml.progressive_delivery -> string

(** [blue_green_service_docs ns name] renders two ClusterIP Services
    ([<name>-active] and [<name>-preview]) required by the blue-green strategy. *)
val blue_green_service_docs : string -> string -> string

val service_doc        : string -> string -> string
val ingress_doc        : ?ingress_host:string -> ?ingress_path:string -> string -> string -> string
val network_policy_doc : string -> string -> string
val cronjob_doc        : ?secret_keys:string list -> string -> string -> string -> string -> string

(** Render a (namespace_yaml, workload_yaml) pair for one service.
    [extra_env] is appended to the ConfigMap data block. *)
val render
  :  ?toml:Sun_cli_toml.t
  -> service
  -> ns:string
  -> name:string
  -> image:string
  -> string * string

exception Deploy_failed of string

val apply     : string * string -> dry_run:bool -> unit
val emit_to_dir : string -> string * string -> ns:string -> name:string -> string
