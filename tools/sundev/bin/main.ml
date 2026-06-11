let () =
  let cmd =
    Cmdliner.Cmd.group
      (Cmdliner.Cmd.info "sundev"
         ~version:"dev"
         ~doc:"Sun internal developer CLI — pipeline operations for Sun development")
      [ Cmd_pipeline.cmd ]
  in
  exit (Cmdliner.Cmd.eval cmd)
