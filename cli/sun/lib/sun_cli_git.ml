let rev_parse_short () =
  match Sun_cli_process.run
      (Sun_cli_process.cmd ["git"; "rev-parse"; "--short"; "HEAD"]) with
  | Ok r when r.Sun_cli_process.exit_code = 0 && r.Sun_cli_process.stdout <> "" ->
    r.Sun_cli_process.stdout
  | _ -> "dev"
