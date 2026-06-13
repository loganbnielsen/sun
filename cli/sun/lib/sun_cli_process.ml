type output = {
  exit_code : int;
  stdout    : string;
  stderr    : string;
  command   : string;
}

(* ── Shell escape hatch ──────────────────────────────────────────────────── *)

(* Run a command through /bin/sh. Use only where shell features are genuinely
   required: background execution (&), redirection (>/>>/2>/dev/null), or
   complex piping. All other call sites should use run or exec instead.
   Document shell: call sites with (* shell: <reason> *). *)
let run_shell ?(echo = true) cmd =
  if echo then Printf.printf "  $ %s\n%!" cmd;
  Sys.command cmd

(* ── Argv-based execution ────────────────────────────────────────────────── *)

let fmt_argv prog args =
  String.concat " " (List.map Filename.quote (prog :: args))

(* Drain both fds using Unix.select to avoid pipe-buffer deadlock. *)
let drain_both fd_out fd_err =
  let buf_o = Buffer.create 256 in
  let buf_e = Buffer.create 256 in
  let open_fds = ref [fd_out; fd_err] in
  let chunk = Bytes.create 4096 in
  (try
    while !open_fds <> [] do
      match Unix.select !open_fds [] [] (-1.0) with
      | [], _, _ -> ()
      | ready, _, _ ->
        List.iter (fun fd ->
          (match Unix.read fd chunk 0 4096 with
           | 0 -> open_fds := List.filter (( <> ) fd) !open_fds
           | n ->
             let buf = if fd = fd_out then buf_o else buf_e in
             Buffer.add_subbytes buf chunk 0 n
           | exception Unix.Unix_error (Unix.EINTR, _, _) -> ())
        ) ready
    done
  with Unix.Unix_error _ -> ());
  (Buffer.contents buf_o, Buffer.contents buf_e)

(* Run [prog args] with stdout and stderr captured.  Deadlock-safe for any
   output volume via select-based draining.  Does not invoke a shell. *)
let run ?(echo = true) prog args =
  let command = fmt_argv prog args in
  if echo then Printf.printf "  $ %s\n%!" command;
  let (out_r, out_w) = Unix.pipe () in
  let (err_r, err_w) = Unix.pipe () in
  let pid =
    Unix.create_process prog (Array.of_list (prog :: args))
      Unix.stdin out_w err_w
  in
  Unix.close out_w;
  Unix.close err_w;
  let (stdout, stderr) = drain_both out_r err_r in
  Unix.close out_r;
  Unix.close err_r;
  let exit_code =
    match Unix.waitpid [] pid with
    | (_, Unix.WEXITED n)   -> n
    | (_, Unix.WSIGNALED _) -> 128
    | (_, Unix.WSTOPPED  _) -> 128
  in
  { exit_code; stdout; stderr; command }

(* Run [prog args] with inherited stdout/stderr (output goes to terminal).
   Returns exit code only.  Does not invoke a shell. *)
let exec ?(echo = true) prog args =
  let command = fmt_argv prog args in
  if echo then Printf.printf "  $ %s\n%!" command;
  let pid =
    Unix.create_process prog (Array.of_list (prog :: args))
      Unix.stdin Unix.stdout Unix.stderr
  in
  match Unix.waitpid [] pid with
  | (_, Unix.WEXITED n)   -> n
  | (_, Unix.WSIGNALED _) -> 128
  | (_, Unix.WSTOPPED  _) -> 128

(* Capture stdout of [prog args] as a trimmed string.
   Returns [Ok stdout] on success or [Error stderr] on non-zero exit. *)
let capture prog args =
  let r = run ~echo:false prog args in
  if r.exit_code = 0 then Ok (String.trim r.stdout)
  else Error (String.trim r.stderr)

(* Assert [name] exists in PATH.  Prints an install hint and exits 1 if not. *)
let check_tool name ~install_url =
  let r = run ~echo:false "which" [name] in
  if r.exit_code <> 0 then begin
    Printf.eprintf "error: %S not found in PATH.\n" name;
    Printf.eprintf "  Install: %s\n" install_url;
    exit 1
  end
