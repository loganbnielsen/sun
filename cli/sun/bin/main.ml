let () =
  let cmd =
    Cmdliner.Cmd.group
      (Cmdliner.Cmd.info "sun"
         ~version:"dev"
         ~doc:"Sun platform CLI — scaffold, run, and deploy Sun services")
      [ Sun_cli_cmd_new.cmd
      ; Cmd_dev.cmd
      ; Cmd_up.cmd
      ; Cmd_deploy.cmd
      ; Cmd_status.cmd
      ; Cmd_logs.cmd
      ; Cmd_migrate.cmd
      ; Cmd_rollback.cmd
      ; Cmd_secret.cmd
      ; Cmd_cloud.cmd
      ]
  in
  exit (Cmdliner.Cmd.eval cmd)
