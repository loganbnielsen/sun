type result = {
  exit_code : int;
  stdout    : string;
  stderr    : string;
}

let exit_of_status = function
  | Unix.WEXITED n   -> n
  | Unix.WSIGNALED n -> 128 + n
  | Unix.WSTOPPED _  -> 128

(* Run [cmd] via /bin/sh and capture stdout + stderr.
   Reads stdout then stderr sequentially; safe for the small outputs typical
   of CLI tools (kubectl, helm, git, docker).  Do not use for commands that
   stream MB+ to stderr while producing stdout. *)
let run ?(echo = false) cmd =
  if echo then Printf.printf "  $ %s\n%!" cmd;
  let ic, oc, ec = Unix.open_process_full cmd (Unix.environment ()) in
  close_out oc;
  let stdout = In_channel.input_all ic in
  let stderr = In_channel.input_all ec in
  let exit_code = exit_of_status (Unix.close_process_full (ic, oc, ec)) in
  { exit_code; stdout = String.trim stdout; stderr = String.trim stderr }

(* Run [argv] without shell interpolation by quoting each element with
   Filename.quote before passing to /bin/sh.  Prevents injection when
   paths or values come from external sources. *)
let run_argv ?echo argv =
  let cmd = String.concat " " (List.map Filename.quote argv) in
  run ?echo cmd

(* Capture stdout lines; stderr goes to /dev/null.
   Uses Unix.open_process_in so no temp file is needed. *)
let lines ?(echo = false) cmd =
  if echo then Printf.printf "  $ %s\n%!" cmd;
  let ic = Unix.open_process_in (cmd ^ " 2>/dev/null") in
  let content = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  List.filter (fun s -> s <> "") (String.split_on_char '\n' (String.trim content))

(* Capture stdout as a trimmed string; stderr goes to /dev/null. *)
let output ?(echo = false) cmd =
  if echo then Printf.printf "  $ %s\n%!" cmd;
  let ic = Unix.open_process_in (cmd ^ " 2>/dev/null") in
  let s = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  String.trim s

(* Run and return exit code only; does not capture output. *)
let run_rc ?(echo = true) cmd =
  if echo then Printf.printf "  $ %s\n%!" cmd;
  Sys.command cmd

(* Run and fail with an informative message if exit code is non-zero. *)
let run_ok ?(echo = true) cmd =
  let rc = run_rc ~echo cmd in
  if rc <> 0 then
    failwith (Printf.sprintf "command failed (exit %d): %s" rc cmd)

(* Write [content] to a temp file, call [f] with the path, then always delete
   the file — whether [f] returns normally or raises. *)
let with_tmp_file prefix content f =
  let path = Filename.temp_file prefix ".tmp" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect ~finally:(fun () -> try Sys.remove path with _ -> ()) (fun () -> f path)

(* Run a shell command and return (exit_code, stdout). Stderr is discarded. *)
let capture_cmd cmd =
  let r = run cmd in
  (r.exit_code, r.stdout)
