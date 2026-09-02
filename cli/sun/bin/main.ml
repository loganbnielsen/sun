let () =
  (* Make every command deterministic from any directory inside the
     workspace, not just the root: chdir to the nearest ancestor containing
     app/ before any subcommand runs, so the many existing Sys.getcwd ()
     /relative-"app" call sites downstream resolve correctly unmodified.
     A no-op outside any workspace (e.g. before sun new's first scaffold). *)
  (match Sun_cli_workspace.find_root ~dir:(Sys.getcwd ()) with
   | Some root -> Sys.chdir root
   | None -> ());
  let cmd =
    Cmdliner.Cmd.group
      (Cmdliner.Cmd.info "sun"
         ~version:"dev"
         ~doc:"Sun platform CLI — scaffold, run, and deploy Sun services")
      [ Sun_cli_cmd_new.cmd
      ; Cmd_dev.cmd
      ; Cmd_plan.cmd
      ; Cmd_up.cmd
      ; Cmd_deploy.cmd
      ; Cmd_status.cmd
      ; Cmd_logs.cmd
      ; Cmd_open.cmd
      ; Cmd_migrate.cmd
      ; Cmd_rollback.cmd
      ; Cmd_secret.cmd
      ; Cmd_cloud.cmd
      ]
  in
  exit (Cmdliner.Cmd.eval cmd)
