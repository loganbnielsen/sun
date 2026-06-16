open Cmdliner
open Sun_cli_manifest

let workspace_name () = Filename.basename (Sys.getcwd ())

let git_sha () =
  let s = Sun_cli_shell.run_cmd_to_string "git rev-parse --short HEAD" in
  if s = "" then "dev" else s

let is_known_local_dev_context () =
  Sun_cli_shell.run_cmd_to_string "kubectl config current-context" = "k3d-sun-local"

let run filter_path dry_run tag confirm_group_change =
  let workspace = workspace_name () in
  let sha       = match tag with Some t -> t | None -> git_sha () in
  let services  = discover_services ~filter_path in
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
  let env_target    = Sun_cli_env_target.local_defaults ~image_tag:sha in
  let env  = Sun_cli_env_target.to_env_config ~name:workspace env_target in
  let plan = Sun_cli_deployment_plan.of_services ~workspace ~env services in

  if not dry_run then begin
    let prev_groups = Sun_cli_deployment_state.load_deployed_groups workspace in
    let next_groups = plan.Sun_cli_deployment_plan.consumer_groups in
    let removed = Sun_cli_deployment_state.removed_consumer_groups ~prev:prev_groups ~next:next_groups in
    if removed <> [] && not confirm_group_change then begin
      Printf.eprintf
        "\nwarning: the following consumer group(s) are no longer present in \
         this deploy plan:\n";
      List.iter (fun g -> Printf.eprintf "  - %s\n" g) removed;
      Printf.eprintf
        "\nMessages produced while the old group is absent will be consumed\n\
         from the latest offset when the group is re-added, silently skipping\n\
         any backlog.  Pass --confirm-group-change to acknowledge and proceed.\n\n";
      exit 1
    end
  end;

  if dry_run then
    Sun_cli_deploy.deploy_services ~dry_run ~workspace ~sha ~push_registry ~ctx_dir:"" plan pf_failed
  else
    Sun_cli_docker.with_context ~repo_root:(Sun_cli_docker.find_repo_root ())
      (fun ctx_dir ->
        (try
           Sun_cli_deploy.deploy_services ~dry_run ~workspace ~sha ~push_registry ~ctx_dir plan pf_failed
         with Deploy_failed msg ->
           Printf.eprintf "\nerror: %s\n" msg;
           exit 1);
        Printf.printf "Done. %d service(s) deployed.\n" (List.length services);
        Printf.printf "Run 'sun status' to check pod health.\n";
        let n = Sun_cli_workspace.pending_migration_count ~dir:(Sys.getcwd ()) in
        if n > 0 then
          Printf.printf
            "\nNote: %d migration file(s) found in db/migrations/ — run 'sun migrate' to apply.\n"
            n;
        Sun_cli_deployment_state.save_deployed_groups workspace plan.Sun_cli_deployment_plan.consumer_groups;
        if !pf_failed then exit 1)

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
    Term.(const run $ path_arg $ dry_run_flag $ tag_arg $ confirm_group_change_flag)
