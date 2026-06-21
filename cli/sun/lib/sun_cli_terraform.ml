let run = Sun_cli_process.run
let cmd = Sun_cli_process.cmd

let which_check () =
  match run (cmd ["which"; "terraform"]) with
  | Ok r -> r.Sun_cli_process.exit_code = 0
  | Error _ -> false

let init ~chdir =
  run ~echo:true (cmd ["terraform"; "init"; "-chdir=" ^ chdir])

let plan ~chdir ~var_files =
  let varfile_args = List.map (fun f -> "-var-file=" ^ f) var_files in
  run ~echo:true (cmd (["terraform"; "plan"; "-chdir=" ^ chdir] @ varfile_args))

let apply ~chdir ~var_files =
  let varfile_args = List.map (fun f -> "-var-file=" ^ f) var_files in
  run ~echo:true (cmd (["terraform"; "apply"; "-auto-approve"; "-chdir=" ^ chdir] @ varfile_args))

let output_json ~chdir =
  run (cmd ["terraform"; "output"; "-json"; "-chdir=" ^ chdir])
