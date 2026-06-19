type common_fields = {
  namespace  : Sun_cli_kubernetes_name.namespace;
  k8s_name   : Sun_cli_kubernetes_name.k8s_name;
  spec_image : string;
  config     : (string * string) list;
  secrets    : (string * string) list;
}

type deployment_fields = {
  replicas             : int;
  cpu                  : string;
  memory               : string;
  rollout_strategy     : Sun_cli_toml.rollout_strategy option;
  extra_labels         : (string * string) list;
  progressive_delivery : Sun_cli_toml.progressive_delivery option;
}

type http_fields = {
  deployment   : deployment_fields;
  ingress_host : string option;
  ingress_path : string option;
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

(** Render a (namespace_yaml, workload_yaml) pair from resolved deployment
    fields.  This module does not construct plans or scan the workspace. *)
let render_spec ?(image = "") ?(secret_backend = Sun_cli_manifest.Kubernetes_live)
    { common; workload } =
  let { namespace; k8s_name; spec_image; config; secrets } = common in
  let ns               = Sun_cli_kubernetes_name.namespace_to_string namespace in
  let name             = Sun_cli_kubernetes_name.k8s_name_to_string k8s_name in
  let img              = if image = "" then spec_image else image in
  let cfg_hash         = Sun_cli_manifest.config_hash config in
  Sun_cli_manifest.(
    let ns_yaml = namespace_doc ~ns in
    let workload_yaml =
      (* Build the secret resource document depending on backend:
         - Kubernetes_live (default): emit a Secret with real values (sun up / live deploy).
         - Kubernetes_placeholder: emit a Secret with empty stringData (GitOps fill-in).
         - External_secrets _: emit an ExternalSecret CRD so ESO materialises the Secret. *)
      let secret_resource = match secret_backend with
        | Kubernetes_live ->
          let value_from_env key =
            match Sys.getenv_opt key with
            | Some value -> value
            | None       -> ""
          in
          let extra_secrets =
            List.map (fun (k, _) -> (k, value_from_env k)) secrets
          in
          let base_secrets =
            List.map (fun (k, _) -> (k, value_from_env k)) default_secrets
          in
          secret_doc ~base_secrets ~extra_secrets ~ns ~name ()
        | Kubernetes_placeholder ->
          let extra_secrets = List.map (fun (k, _) -> (k, "")) secrets in
          secret_doc ~extra_secrets ~redact:true ~ns ~name ()
        | External_secrets { store_ref; store_kind; key_prefix; refresh_interval } ->
          let all_keys =
            List.map fst default_secrets @ List.map fst secrets
          in
          external_secret_doc ~store_ref ~store_kind ~key_prefix ~refresh_interval
            ~secret_keys:all_keys ~ns ~name
      in
      let common = [
        service_account_doc ~ns ~name;
        configmap_doc ~extra_env:config ~ns ~name ();
        secret_resource;
        network_policy_doc ~ns ~name;
      ] in
      let deployment_resources ~shape ~ingress_host ~ingress_path ~deployment =
        let { replicas; cpu; memory; rollout_strategy; extra_labels; progressive_delivery } =
          deployment
        in
        match progressive_delivery with
        (* ── Argo Rollouts paths ─────────────────────────────────────────── *)
        | Some pd ->
          let rollout = rollout_doc ~extra_labels ~secret_keys:(List.map fst secrets) ~config_hash:cfg_hash ~shape ~replicas ~cpu ~memory ~ns ~name ~image:img ~pd () in
          (match pd with
           | Sun_cli_toml.Blue_green ->
             [ rollout
             ; blue_green_service_docs ~ns ~name
             ; (if shape = Http_service then ingress_doc ~ingress_host ~ingress_path ~ns ~name:(name ^ "-active") ()
                else "")
             ]
             |> List.filter (fun s -> s <> "")
           | Sun_cli_toml.Canary _ ->
             let svc    = if shape = Http_service then [service_doc ~ns ~name] else [] in
             let ingr   = if shape = Http_service then [ingress_doc ~ingress_host ~ingress_path ~ns ~name ()] else [] in
             [ rollout ] @ svc @ ingr)
        (* ── Standard Deployment paths ────────────────────────────────────── *)
        | None ->
          let rollout_strategy = Option.value rollout_strategy
                                   ~default:Sun_cli_toml.RollingUpdate in
          [ deployment_doc ~rollout_strategy ~extra_labels ~config_hash:cfg_hash
              ~secret_keys:(List.map fst secrets)
              ~shape ~replicas ~cpu ~memory ~ns ~name ~image:img () ]
      in
      let resources = match workload with
        | Render_svc { deployment; ingress_host; ingress_path } ->
          let ingress_host = Option.value ingress_host ~default:"" in
          let ingress_path = Option.value ingress_path ~default:"/" in
          let resources =
            deployment_resources ~shape:Http_service ~ingress_host ~ingress_path ~deployment
          in
          (match deployment.progressive_delivery with
           | Some _ -> resources
           | None -> resources @ [ service_doc ~ns ~name; ingress_doc ~ingress_host ~ingress_path ~ns ~name () ])
        | Render_worker { deployment } ->
          deployment_resources ~shape:Background_worker ~ingress_host:"" ~ingress_path:"/" ~deployment
        | Render_fn { schedule } ->
          [ cronjob_doc ~secret_keys:(List.map fst secrets) ~ns ~name ~image:img ~schedule () ]
      in
      String.concat "\n" (common @ resources)
    in
    (ns_yaml, workload_yaml)
  )
