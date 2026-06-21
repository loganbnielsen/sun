type common_fields = {
  namespace  : Sun_cli_kubernetes_name.namespace;
  k8s_name   : Sun_cli_kubernetes_name.k8s_name;
  spec_image : string;
  config     : (string * string) list;
  secrets    : (string * string) list;
}

type deployment_fields = {
  replicas             : int;
  cpu                  : Sun_cli_toml.cpu_quantity;
  memory               : Sun_cli_toml.memory_quantity;
  rollout_strategy     : Sun_cli_toml.rollout_strategy option;
  extra_labels         : (string * string) list;
  progressive_delivery : Sun_cli_toml.progressive_delivery option;
}

type http_fields = {
  deployment   : deployment_fields;
  ingress_host : Sun_cli_toml.hostname option;
  ingress_path : Sun_cli_toml.ingress_path option;
}

type worker_fields = {
  deployment : deployment_fields;
}

type fn_fields = {
  schedule : string;
}

type workload =
  | Render_svc of http_fields
  | Render_worker of worker_fields
  | Render_fn of fn_fields

type spec = {
  common   : common_fields;
  workload : workload;
}

val render_spec :
  ?image:string ->
  ?secret_backend:Sun_cli_manifest.secret_backend ->
  spec ->
  (string * string, string) result
(** Returns [Ok (namespace_yaml, workload_yaml)] on success.
    Returns [Error msg] when [secret_backend = Kubernetes_live] and one or
    more user-declared secret env vars (from [common.secrets]) are absent
    from the process environment. *)
