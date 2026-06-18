type primitive = Render_svc | Render_worker | Render_fn

val render_spec :
  ?image:string ->
  ?secret_backend:Sun_cli_manifest.secret_backend ->
  namespace:Sun_cli_kubernetes_name.namespace ->
  k8s_name:Sun_cli_kubernetes_name.k8s_name ->
  primitive:primitive ->
  spec_image:string ->
  config:(string * string) list ->
  secrets:(string * string) list ->
  schedule:string option ->
  replicas:int ->
  cpu:string ->
  memory:string ->
  rollout_strategy:Sun_cli_toml.rollout_strategy option ->
  ingress_host:string option ->
  ingress_path:string option ->
  extra_labels:(string * string) list ->
  progressive_delivery:Sun_cli_toml.progressive_delivery option ->
  unit ->
  string * string
