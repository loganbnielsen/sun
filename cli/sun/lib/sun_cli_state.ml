let dir =
  match Sys.getenv_opt "XDG_DATA_HOME" with
  | Some d -> Filename.concat d "sun"
  | None ->
    match Sys.getenv_opt "HOME" with
    | Some h -> Filename.concat h ".local/share/sun"
    | None   -> Filename.concat (Sys.getcwd ()) ".sun"

let ensure () =
  ignore (Sun_process.run_rc ~echo:false (Printf.sprintf "mkdir -p %s" (Filename.quote dir)))

let pid_file name    = Printf.sprintf "%s/pf-%s.pid" dir name
let log_file name    = Printf.sprintf "/tmp/sun-pf-%s.log" name
let script_file name = Printf.sprintf "/tmp/sun-pf-%s.sh" name
