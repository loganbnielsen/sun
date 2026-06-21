type rendered_artifact = {
  namespace_yaml : string;
  workload_yaml  : string;
  namespace      : string;
  name           : string;
  image          : string;
}

type rendered_artifacts = rendered_artifact list

type execution_mode =
  | Dry_run
  | Emit_to of string
  | Apply

type change_set = {
  plan      : Sun_cli_deployment_plan.t;
  artifacts : rendered_artifacts;
  mode      : execution_mode;
}

let render_artifact ?(secret_backend = Sun_cli_manifest.Kubernetes_live)
    (spec : Sun_cli_deployment_plan.service_spec) =
  let (ns_yaml, wl_yaml) =
    Sun_cli_deployment_plan.render_spec ~secret_backend spec
  in
  { namespace_yaml = ns_yaml
  ; workload_yaml  = wl_yaml
  ; namespace      = Sun_cli_deployment_plan.namespace_to_string spec.namespace
  ; name           = Sun_cli_deployment_plan.k8s_name_to_string spec.k8s_name
  ; image          = spec.image
  }

let build ~plan ~mode ?(secret_backend = Sun_cli_manifest.Kubernetes_live) () =
  let backend = match mode with
    | Emit_to _ -> Sun_cli_manifest.Kubernetes_placeholder
    | Dry_run | Apply -> secret_backend
  in
  let artifacts =
    List.map (render_artifact ~secret_backend:backend) plan.Sun_cli_deployment_plan.services
  in
  { plan; artifacts; mode }

let execute cs =
  List.map2
    (fun (spec : Sun_cli_deployment_plan.service_spec) art ->
       match cs.mode with
       | Dry_run ->
         Sun_cli_manifest.apply (art.namespace_yaml, art.workload_yaml) ~dry_run:true;
         { Sun_cli_executor.namespace = art.namespace
         ; name  = art.name
         ; image = art.image
         }
       | Emit_to dir ->
         let _path =
           Sun_cli_manifest.emit_to_dir dir (art.namespace_yaml, art.workload_yaml)
             ~ns:art.namespace ~name:art.name
         in
         { Sun_cli_executor.namespace = art.namespace
         ; name  = art.name
         ; image = art.image
         }
       | Apply ->
         Sun_cli_manifest.apply (art.namespace_yaml, art.workload_yaml) ~dry_run:false;
         { Sun_cli_executor.namespace = art.namespace
         ; name  = art.name
         ; image = spec.image
         })
    cs.plan.Sun_cli_deployment_plan.services
    cs.artifacts
