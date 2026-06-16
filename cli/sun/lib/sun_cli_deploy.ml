open Sun_cli_manifest

let wait_for_rollout ~namespace ~name =
  let cmd = Printf.sprintf
    "kubectl rollout status deployment/%s -n %s --timeout=60s"
    (Filename.quote name) (Filename.quote namespace)
  in
  Sun_cli_shell.run_cmd ~echo:false cmd

let deploy_services ~dry_run ~workspace ~sha ~push_registry ~ctx_dir plan pf_failed =
  List.iter (fun (spec : Sun_cli_deployment_plan.service_spec) ->
    let push_image = Sun_cli_deployment_plan.image_ref
      ~registry:push_registry ~workspace
      ~k8s_name:spec.k8s_name ~tag:sha in

    Printf.printf "[%s] %s/%s\n%!" (prim_label
      (match spec.primitive with
       | Sun_cli_deployment_plan.Svc    -> Svc
       | Sun_cli_deployment_plan.Worker -> Worker
       | Sun_cli_deployment_plan.Fn     -> Fn))
      spec.domain spec.source_name;

    if not dry_run then begin
      (match Sun_cli_docker.build_and_push ~ctx_dir ~push_image
               ~source_dir:spec.source_dir with
       | Error msg -> raise (Deploy_failed msg)
       | Ok () -> ())
    end;

    let exec_spec =
      if dry_run then { spec with Sun_cli_deployment_plan.image = push_image }
      else spec
    in
    ignore (Sun_cli_executor.local ~dry_run exec_spec);

    if not dry_run then begin
      (match spec.primitive with
       | Sun_cli_deployment_plan.Svc
       | Sun_cli_deployment_plan.Worker ->
         Printf.printf "  waiting for rollout...\n%!";
         if wait_for_rollout ~namespace:spec.namespace ~name:spec.k8s_name <> 0 then
           raise (Deploy_failed (Printf.sprintf "rollout failed: %s/%s" spec.namespace spec.k8s_name))
       | Sun_cli_deployment_plan.Fn -> ());
      (match spec.primitive with
       | Sun_cli_deployment_plan.Svc ->
         let local_port = 8080 in
         if not (Sun_cli_port_forward.is_running spec.k8s_name) then begin
           if Sun_cli_port_forward.detect_stale ~local_port
                ~namespace:spec.namespace ~target:("svc/" ^ spec.k8s_name)
           then Unix.sleepf 0.4;
           Sun_cli_port_forward.start {
             name        = spec.k8s_name;
             namespace   = spec.namespace;
             target      = "svc/" ^ spec.k8s_name;
             local_port;
             remote_port = 80;
           }
         end;
         let pf_alive = Sun_cli_port_forward.check_alive ~name:spec.k8s_name ~local_port in
         Printf.printf "  ✓  namespace %s  image %s\n%!" spec.namespace spec.image;
         if pf_alive then
           Printf.printf "  →  http://localhost:%d  (port-forward running in background)\n\n%!" local_port
         else begin
           pf_failed := true;
           Printf.printf "\n%!"
         end
       | _ ->
         Printf.printf "  ✓  namespace %s  image %s\n%!" spec.namespace spec.image;
         Printf.printf "\n%!")
    end
  ) plan.Sun_cli_deployment_plan.services
