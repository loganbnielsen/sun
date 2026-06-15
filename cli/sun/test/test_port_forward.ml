(** Unit tests for Sun_cli_port_forward.

    These tests only check properties that can be verified without a running
    kubectl, cluster, or network access. *)

let () = Random.self_init ()

(* ── state_dir is an absolute path ───────────────────────────────────────── *)

let () =
  let dir = Sun_cli_port_forward.state_dir in
  let is_absolute = String.length dir > 0 && dir.[0] = '/' in
  if not is_absolute then begin
    Printf.eprintf "FAIL state_dir is not absolute: %s\n%!" dir;
    exit 1
  end;
  (* Must not contain a bare ".." path component that could escape the intended
     directory.  We check for "/.." (or the path starting with "..") as a
     proxy for relative traversal. *)
  let has_dotdot =
    let n = String.length dir in
    (n >= 2 && String.sub dir 0 2 = "..")
    || (let rec check i =
          if i + 3 > n then false
          else if String.sub dir i 3 = "/.." then true
          else check (i + 1)
        in check 0)
  in
  if has_dotdot then begin
    Printf.eprintf "FAIL state_dir contains '..' traversal: %s\n%!" dir;
    exit 1
  end;
  Printf.printf "OK  state_dir is absolute (%s)\n%!" dir

(* ── pid_file path format ─────────────────────────────────────────────────── *)

let () =
  let name = "kafka" in
  let pf = Sun_cli_port_forward.pid_file name in
  let suffix = "/pf-" ^ name ^ ".pid" in
  let has_suffix =
    let pl = String.length pf and sl = String.length suffix in
    pl >= sl && String.sub pf (pl - sl) sl = suffix
  in
  if not has_suffix then begin
    Printf.eprintf "FAIL pid_file %S does not end with %S\n%!" pf suffix;
    exit 1
  end;
  (* Must also be an absolute path *)
  if String.length pf = 0 || pf.[0] <> '/' then begin
    Printf.eprintf "FAIL pid_file result is not absolute: %s\n%!" pf;
    exit 1
  end;
  Printf.printf "OK  pid_file \"kafka\" → %s\n%!" pf

(* ── pid_file round-trip write/read ──────────────────────────────────────── *)

let () =
  (* Use a unique temp name to avoid collisions with a real running instance *)
  let name = Printf.sprintf "test-%d-%d" (Unix.getpid ()) (Random.int 999999) in
  Sun_cli_port_forward.ensure_state_dir ();
  let pf = Sun_cli_port_forward.pid_file name in
  (* Write a fake PID *)
  let fake_pid = 99999 in
  let oc = open_out pf in
  Printf.fprintf oc "%d\n" fake_pid;
  close_out oc;
  (* Read it back *)
  let ic = open_in pf in
  let content = String.trim (In_channel.input_all ic) in
  close_in ic;
  (try Sys.remove pf with _ -> ());
  (match int_of_string_opt content with
   | Some n when n = fake_pid ->
     Printf.printf "OK  pid_file round-trip (pid=%d)\n%!" fake_pid
   | Some n ->
     Printf.eprintf "FAIL round-trip got %d, expected %d\n%!" n fake_pid;
     exit 1
   | None ->
     Printf.eprintf "FAIL round-trip content %S is not an integer\n%!" content;
     exit 1)
