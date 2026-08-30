let dir =
  match Sys.getenv_opt "XDG_DATA_HOME" with
  | Some d -> Filename.concat d "sun"
  | None ->
    match Sys.getenv_opt "HOME" with
    | Some h -> Filename.concat h ".local/share/sun"
    | None   -> Filename.concat (Sys.getcwd ()) ".sun"

let ensure () = Sun_cli_scaffold.mkdir_p dir

let pid_file name    = Printf.sprintf "%s/pf-%s.pid" dir name
let log_file name    = Printf.sprintf "/tmp/sun-pf-%s.log" name
let script_file name = Printf.sprintf "/tmp/sun-pf-%s.sh" name
