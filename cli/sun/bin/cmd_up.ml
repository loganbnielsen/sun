open Cmdliner
open Sun_cli_manifest

let wait_for_rollout ~namespace ~name =
  let cmd = Printf.sprintf
    "kubectl rollout status deployment/%s -n %s --timeout=60s"
    (Filename.quote name) (Filename.quote namespace)
  in
  Sun_cli_shell.run_cmd ~echo:false cmd

let workspace_name () = Filename.basename (Sys.getcwd ())

let git_sha () =
  let s = Sun_cli_shell.run_cmd_to_string "git rev-parse --short HEAD" in
  if s = "" then "dev" else s

let current_kube_context () =
  Sun_cli_shell.run_cmd_to_string "kubectl config current-context"

let is_known_local_dev_context () =
  current_kube_context () = "k3d-sun-local"

let find_repo_root () =
  let rec go dir =
    if Sys.file_exists (Filename.concat dir "dune-workspace") then dir
    else if Sys.file_exists (Filename.concat dir "dune-project") then dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then dir
      else go parent
  in
  go (Sys.getcwd ())

let run ~filter_path ~dry_run ~tag ~confirm_group_change () =
  let workspace = workspace_name () in
  let sha       = match tag with Some t -> t | None -> git_sha () in
  let services  = discover_services ~filter_path in
  let repo_root = find_repo_root () in
  let pf_failed = ref false in

  if services = [] then begin
    Printf.eprintf "No services found in app/ with a Dockerfile.\n";
    exit 1
  end;

  if not dry_run then begin
    if is_known_local_dev_context () then begin
      (match Sys.getenv_opt "POSTGRES_URL" with
       | None | Some "" ->
         Unix.putenv "POSTGRES_URL"
           "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev"
       | Some _ -> ())
    end else begin
      match Sys.getenv_opt "POSTGRES_URL" with
      | None | Some "" ->
        Printf.eprintf
          "error: POSTGRES_URL is not set.\n\
           Set it in your environment before running 'sun up':\n\
           \  export POSTGRES_URL=postgresql://user:pass@host:5432/dbname\n";
        exit 1
      | Some _ -> ()
    end
  end;

  Printf.printf "\nWorkspace: %s  tag: %s\n" workspace sha;
  if dry_run then Printf.printf "(dry-run)\n";
  Printf.printf "\n%!";

  let push_registry = "localhost:5000" in
  let req : Sun_cli_deployment_pipeline.request = {
    workspace;
    image_tag            = sha;
    filter_path;
    emit_to              = None;
    secret_backend       = Sun_cli_manifest.Kubernetes_live;
    confirm_group_change;
    dry_run;
  } in
  let env = Sun_cli_deployment_pipeline.resolve_local ~image_tag:sha ~workspace in
  let plan =
    match Sun_cli_deployment_pipeline.build_plan req env services with
    | Ok plan -> plan
    | Error (Sun_cli_deployment_pipeline.Consumer_group_change { removed }) ->
      Printf.eprintf
        "\nwarning: the following consumer group(s) are no longer present in \
         this deploy plan:\n";
      List.iter (fun g -> Printf.eprintf "  - %s\n" g) removed;
      Printf.eprintf
        "\nMessages produced while the old group is absent will be consumed\n\
         from the latest offset when the group is re-added, silently skipping\n\
         any backlog.  Pass --confirm-group-change to acknowledge and proceed.\n\n";
      exit 1
    | Error err ->
      Printf.eprintf "error: %s\n" (Sun_cli_deployment_pipeline.pipeline_error_to_string err);
      exit 1
  in

  let ctx_dir = repo_root ^ ".docker-ctx" in
  if not dry_run then begin
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir)));
    Printf.printf "Preparing build context...\n%!";
    let rsync_cmd = Printf.sprintf
      "rsync -a --copy-links --exclude='_build' --exclude='.git' %s/ %s"
      (Filename.quote repo_root) (Filename.quote ctx_dir) in
    if Sys.command rsync_cmd <> 0 then begin
      Printf.eprintf "error: failed to copy workspace for docker build context\n";
      exit 1
    end
  end;

  let image_override spec =
    Sun_cli_deployment_plan.image_ref
      ~registry:push_registry ~workspace
      ~k8s_name:spec.Sun_cli_deployment_plan.k8s_name ~tag:sha
  in
  let artifacts = Sun_cli_deployment_pipeline.render_artifacts
    ~image_override:(if dry_run then image_override else fun _ -> "")
    ~secret_backend:Sun_cli_manifest.Kubernetes_live
    plan
  in

  (try
    List.iter (fun (artifact : Sun_cli_deployment_pipeline.artifact) ->
      let spec     = artifact.spec in
      let k8s_name = Sun_cli_deployment_plan.k8s_name_to_string spec.k8s_name in
      let namespace = Sun_cli_deployment_plan.namespace_to_string spec.namespace in
      let push_image = image_override spec in

      Printf.printf "[%s] %s/%s\n%!" (prim_label
        (match spec.primitive with
         | Sun_cli_deployment_plan.Svc    -> Svc
         | Sun_cli_deployment_plan.Worker -> Worker
         | Sun_cli_deployment_plan.Fn     -> Fn))
        spec.domain spec.source_name;

      if not dry_run then begin
        Printf.printf "  packaging %s...\n%!" push_image;
        let build_ctx  = ctx_dir in
        let dockerfile = Printf.sprintf "%s/%s/Dockerfile" build_ctx spec.source_dir in
        if not (Sun_process.succeeded
              (Sun_process.run_argv ~echo:false
                 ["docker"; "build"; "-t"; push_image; "-f"; dockerfile; ctx_dir])) then
          raise (Deploy_failed (Printf.sprintf "docker build failed: %s" spec.source_dir));
        Printf.printf "  pushing...\n%!";
        if not (Sun_process.succeeded
              (Sun_process.run_argv ~echo:false ["docker"; "push"; push_image])) then
          raise (Deploy_failed (Printf.sprintf "docker push failed: %s" push_image))
      end;

      ignore (Sun_cli_deployment_pipeline.apply_artifact ~dry_run artifact);

      if not dry_run then begin
        (match spec.primitive with
         | Sun_cli_deployment_plan.Svc
         | Sun_cli_deployment_plan.Worker ->
           Printf.printf "  waiting for rollout...\n%!";
           if wait_for_rollout ~namespace ~name:k8s_name <> 0 then
             raise (Deploy_failed (Printf.sprintf "rollout failed: %s/%s" namespace k8s_name))
         | Sun_cli_deployment_plan.Fn -> ());
        (match spec.primitive with
         | Sun_cli_deployment_plan.Svc ->
           let local_port = 8080 in
           if not (Sun_cli_port_forward.is_running k8s_name) then begin
             if Sun_cli_port_forward.detect_stale ~local_port
                  ~namespace ~target:("svc/" ^ k8s_name)
             then Unix.sleepf 0.4;
             Sun_cli_port_forward.start {
               name        = k8s_name;
               namespace;
               target      = "svc/" ^ k8s_name;
               local_port;
               remote_port = 80;
             }
           end;
           let pf_alive = Sun_cli_port_forward.check_alive ~name:k8s_name ~local_port in
           Printf.printf "  ✓  namespace %s  image %s\n%!" namespace spec.image;
           if pf_alive then
             Printf.printf "  →  http://localhost:%d  (port-forward running in background)\n\n%!" local_port
           else begin
             pf_failed := true;
             Printf.printf "\n%!"
           end
         | _ ->
           Printf.printf "  ✓  namespace %s  image %s\n%!" namespace spec.image;
           Printf.printf "\n%!")
      end

    ) artifacts
  with Deploy_failed msg ->
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir)));
    Printf.eprintf "\nerror: %s\n" msg;
    exit 1);

  if not dry_run then begin
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir)));
    Printf.printf "Done. %d service(s) deployed.\n" (List.length services);
    Printf.printf "Run 'sun status' to check pod health.\n";
    let n = Sun_cli_workspace.pending_migration_count ~dir:(Sys.getcwd ()) in
    if n > 0 then
      Printf.printf
        "\nNote: %d migration file(s) found in db/migrations/ — run 'sun migrate' to apply.\n"
        n;
    Sun_cli_deployment_state.save_deployed_groups workspace plan.Sun_cli_deployment_plan.consumer_groups;
    if !pf_failed then exit 1
  end

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let path_arg =
  Arg.(value & pos 0 (some string) None &
       info [] ~docv:"PATH"
         ~doc:"Service path to build and deploy (default: all services in workspace)")

let dry_run_flag =
  Arg.(value & flag &
       info ["dry-run"]
         ~doc:"Print synthesized YAML to stdout without applying to the cluster")

let tag_arg =
  Arg.(value & opt (some string) None &
       info ["tag"] ~docv:"TAG"
         ~doc:"Docker image tag (default: short git SHA)")

let confirm_group_change_flag =
  Arg.(value & flag &
       info ["confirm-group-change"]
         ~doc:"Acknowledge that consumer group IDs have changed and proceed with deploy")

let cmd =
  Cmd.v
    (Cmd.info "up"
       ~doc:"Build images, synthesize k8s manifests, and deploy to the cluster")
    Term.(const (fun filter_path dry_run tag confirm_group_change ->
        run ~filter_path ~dry_run ~tag ~confirm_group_change ())
      $ path_arg $ dry_run_flag $ tag_arg $ confirm_group_change_flag)
