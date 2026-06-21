type request = {
  workspace            : string;
  image_tag            : string;
  filter_path          : string option;
  emit_to              : string option;
  secret_backend       : Sun_cli_manifest.secret_backend;
  confirm_group_change : bool;
  dry_run              : bool;
}

type resolved_environment = {
  env_target : Sun_cli_env_target.t;
  env_config : Sun_cli_deployment_plan.env_config;
}

type pipeline_error =
  | Env_validation_error of string
  | No_services_found
  | Plan_error of Sun_cli_deployment_plan.plan_error
  | Consumer_group_change of { removed : string list }

let pipeline_error_to_string = function
  | Env_validation_error msg  -> msg
  | No_services_found         -> "No services found in app/ with a Dockerfile."
  | Plan_error err            -> Sun_cli_deployment_plan.plan_error_to_string err
  | Consumer_group_change { removed } ->
    Printf.sprintf
      "The following consumer group(s) are no longer present in this deploy \
       plan: %s\nPass --confirm-group-change to acknowledge and proceed."
      (String.concat ", " removed)

let resolve_local ~image_tag ~workspace =
  let env_target = Sun_cli_env_target.local_defaults ~image_tag in
  let env_config = Sun_cli_env_target.to_env_config ~name:workspace env_target in
  { env_target; env_config }

let resolve_customer_cloud ~registry ~image_tag ~workspace ~emit_to ~secret_backend =
  let env_target = Sun_cli_env_target.customer_cloud_defaults
    ~registry ~image_tag ~emit_to () in
  match Sun_cli_env_target.validate env_target with
  | Error msg -> Error (Env_validation_error msg)
  | Ok () ->
    let base = Sun_cli_env_target.to_env_config ~name:workspace env_target in
    let env_config = { base with Sun_cli_deployment_plan.secret_backend } in
    Ok { env_target; env_config }

let build_plan req env services =
  let ( let* ) = Result.bind in
  let* plan =
    Sun_cli_deployment_plan.of_services_result
      ~workspace:req.workspace
      ~env:env.env_config
      services
    |> Result.map_error (fun e -> Plan_error e)
  in
  let skip_group_guard = req.dry_run || req.emit_to <> None in
  if skip_group_guard then Ok plan
  else begin
    let prev_groups = Sun_cli_deployment_state.load_deployed_groups req.workspace in
    let next_groups = plan.Sun_cli_deployment_plan.consumer_groups in
    let removed = Sun_cli_deployment_state.removed_consumer_groups
      ~prev:prev_groups ~next:next_groups in
    if removed <> [] && not req.confirm_group_change then
      Error (Consumer_group_change { removed })
    else
      Ok plan
  end

type artifact = {
  spec          : Sun_cli_deployment_plan.service_spec;
  ns_yaml       : string;
  workload_yaml : string;
}

let render_artifacts ?(image_override = fun _ -> "") ~secret_backend plan =
  List.map (fun spec ->
    let override = image_override spec in
    let (ns_yaml, workload_yaml) =
      Sun_cli_deployment_plan.render_spec ~image:override ~secret_backend spec
    in
    { spec; ns_yaml; workload_yaml }
  ) plan.Sun_cli_deployment_plan.services

type execution_result = {
  namespace : string;
  name      : string;
  image     : string;
}

let apply_artifact ~dry_run artifact =
  let yaml = (artifact.ns_yaml, artifact.workload_yaml) in
  Sun_cli_manifest.apply yaml ~dry_run;
  { namespace = Sun_cli_deployment_plan.namespace_to_string artifact.spec.namespace
  ; name      = Sun_cli_deployment_plan.k8s_name_to_string  artifact.spec.k8s_name
  ; image     = artifact.spec.image
  }

let emit_artifact ~dir artifact =
  let yaml = (artifact.ns_yaml, artifact.workload_yaml) in
  let ns   = Sun_cli_deployment_plan.namespace_to_string artifact.spec.namespace in
  let name = Sun_cli_deployment_plan.k8s_name_to_string  artifact.spec.k8s_name in
  ignore (Sun_cli_manifest.emit_to_dir dir yaml ~ns ~name);
  { namespace = ns; name; image = artifact.spec.image }
