(** Shared port-forward lifecycle management for [sun dev up] and [sun up].

    Handles:
    - State directory resolution (XDG-aware, session-independent)
    - PID file read/write/cleanup
    - Wrapper script generation and backgrounding
    - Liveness checks after startup
    - Stale port-forward detection via [/proc] / [ps] / [ss] *)

(* ── State directory ─────────────────────────────────────────────────────── *)

(** Absolute path to the Sun state directory.  Uses XDG_DATA_HOME when set so
    that all [sun dev up] / [sun up] / [sun down] calls share state regardless
    of the working directory. *)
let state_dir =
  match Sys.getenv_opt "XDG_DATA_HOME" with
  | Some d -> Filename.concat d "sun"
  | None ->
    match Sys.getenv_opt "HOME" with
    | Some h -> Filename.concat h ".local/share/sun"
    | None   -> Filename.concat (Sys.getcwd ()) ".sun"

let ensure_state_dir () =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote state_dir)))

(* ── PID / log / script paths ────────────────────────────────────────────── *)

let pid_file name = Printf.sprintf "%s/pf-%s.pid" state_dir name
let log_file name = Printf.sprintf "/tmp/sun-pf-%s.log" name
let script_file name = Printf.sprintf "/tmp/sun-pf-%s.sh" name

(* ── pf_spec — used by cmd_dev for its multi-target port-forwards ─────────── *)

(** Port-forward specification for [dev up], which may target pods as well as
    services (e.g. [pod/redpanda-0] for the Kafka external listener). *)
type pf_spec = {
  name        : string;
  namespace   : string;
  (** Full kubectl resource target, e.g. ["svc/redpanda"] or ["pod/redpanda-0"]. *)
  target      : string;
  local_port  : int;
  remote_port : int;
}

(* ── Wrapper script generation ───────────────────────────────────────────── *)

(** Write a self-restarting wrapper script for a [pf_spec] and background it in
    a new session via [setsid].  Used by [cmd_dev]. *)
let start_port_forward_spec pf =
  Printf.printf "  port-forward  %-12s localhost:%d → %s/%s:%d\n%!"
    pf.name pf.local_port pf.namespace pf.target pf.remote_port;
  ensure_state_dir ();
  let lf = log_file pf.name in
  let sf = script_file pf.name in
  let content = Printf.sprintf
    "#!/bin/sh\necho $$ > %s\nwhile true; do\n  kubectl port-forward -n %s %s %d:%d </dev/null >> %s 2>&1\n  sleep 1\ndone\n"
    (Filename.quote (pid_file pf.name))
    (Filename.quote pf.namespace) (Filename.quote pf.target)
    pf.local_port pf.remote_port
    (Filename.quote lf)
  in
  let oc = open_out sf in
  output_string oc content;
  close_out oc;
  ignore (Sys.command (Printf.sprintf "chmod +x %s" (Filename.quote sf)));
  ignore (Sun_cli_shell.run_cmd ~echo:false
    (Printf.sprintf "setsid %s </dev/null >/dev/null 2>&1 &" (Filename.quote sf)))

(** Write a self-restarting wrapper script for a named [svc/] target and
    background it.  Used by [cmd_up] which always targets services. *)
let start_port_forward ~name ~namespace ~service ~local_port ~remote_port =
  ensure_state_dir ();
  let sf = script_file name in
  let lf = log_file name in
  let pf = pid_file name in
  let content = Printf.sprintf
    "#!/bin/sh\necho $$ > %s\nwhile true; do\n  kubectl port-forward -n %s svc/%s %d:%d </dev/null >> %s 2>&1\n  sleep 1\ndone\n"
    (Filename.quote pf)
    (Filename.quote namespace) (Filename.quote service)
    local_port remote_port
    (Filename.quote lf)
  in
  let oc = open_out sf in
  output_string oc content;
  close_out oc;
  ignore (Sys.command (Printf.sprintf "chmod +x %s" (Filename.quote sf)));
  ignore (Sun_cli_shell.run_cmd ~echo:false
    (Printf.sprintf "setsid %s </dev/null >/dev/null 2>&1 &" (Filename.quote sf)))

(* ── Cleanup ─────────────────────────────────────────────────────────────── *)

(** Kill all Sun-managed port-forward processes recorded in the state directory
    and remove their PID files.  Safe to call when no forwards are running. *)
let stop_port_forwards () =
  if Sys.file_exists state_dir then begin
    let entries = try Sys.readdir state_dir with _ -> [||] in
    Array.iter (fun f ->
      if Filename.check_suffix f ".pid" then begin
        let path = Printf.sprintf "%s/%s" state_dir f in
        (try
          let ic = open_in path in
          let pid_s = String.trim (In_channel.input_all ic) in
          close_in ic;
          (match int_of_string_opt pid_s with
           | Some pid -> ignore (Sun_cli_shell.run_cmd ~echo:false (Printf.sprintf "kill %d 2>/dev/null" pid))
           | None -> ());
          Sys.remove path
        with _ -> ())
      end
    ) entries
  end

(* ── Liveness check ──────────────────────────────────────────────────────── *)

(** Read the last [n] lines of a file, or [""] if the file is missing/empty. *)
let read_last_lines path n =
  try
    let ic = open_in path in
    let content = In_channel.input_all ic in
    close_in ic;
    let lines = String.split_on_char '\n' (String.trim content) in
    let total = List.length lines in
    let tail = if total <= n then lines
               else
                 let rec drop k lst = if k = 0 then lst else drop (k-1) (List.tl lst) in
                 drop (total - n) lines
    in
    String.concat "\n" tail
  with _ -> ""

(** Sleep 200 ms, then check whether the port-forward process for [name] is
    still alive.  Returns [true] if alive, [false] if dead.  When dead, prints
    a warning with the log path and a suggested remediation command. *)
let check_port_forward_liveness ~name ~local_port =
  Unix.sleepf 0.2;
  let pf = pid_file name in
  let alive =
    if Sys.file_exists pf then begin
      try
        let ic = open_in pf in
        let pid_s = String.trim (In_channel.input_all ic) in
        close_in ic;
        let pid = int_of_string pid_s in
        (try Unix.kill pid 0; true
         with Unix.Unix_error (Unix.ESRCH, _, _) -> false
            | Unix.Unix_error _ -> true)  (* EPERM means process exists *)
      with _ -> false
    end else false
  in
  if not alive then begin
    let lf = log_file name in
    let tail = read_last_lines lf 5 in
    Printf.printf
      "  warning: port-forward for %s failed (port %d may be in use by another workspace).\n"
      name local_port;
    Printf.printf "           See %s for details.\n" lf;
    if tail <> "" then
      Printf.printf "           Last log lines:\n             %s\n"
        (String.concat "\n             " (String.split_on_char '\n' tail));
    Printf.printf "           Run: kill $(lsof -ti:%d) && sun up\n%!" local_port
  end;
  alive

(* ── Running-check via PID file + cmdline ────────────────────────────────── *)

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else
    let rec go i =
      i <= hl - nl
      && (String.sub haystack i nl = needle || go (i + 1))
    in
    go 0

let read_cmdline_via_ps pid =
  let tmp = Filename.temp_file "sun-ps-" ".tmp" in
  ignore (Sys.command (Printf.sprintf "ps -p %d -o args= > %s 2>/dev/null" pid (Filename.quote tmp)));
  let ic = open_in tmp in
  let s = String.trim (In_channel.input_all ic) in
  close_in ic;
  (try Sys.remove tmp with _ -> ());
  s

(** Check whether a Sun-managed port-forward for [name] is still running.
    Identifies the wrapper by matching the script file name in the process's
    cmdline.  Removes a stale PID file when the process is found dead. *)
let port_forward_running ~service:_ name =
  let pf = pid_file name in
  if Sys.file_exists pf then begin
    let ic = open_in pf in
    let pid_s = String.trim (In_channel.input_all ic) in
    close_in ic;
    try
      let pid = int_of_string pid_s in
      let alive = Sys.command (Printf.sprintf "kill -0 %d 2>/dev/null" pid) = 0 in
      let args = if alive then read_cmdline_via_ps pid else "" in
      let ok = alive && contains args (Printf.sprintf "sun-pf-%s.sh" name) in
      if not ok then (try Sys.remove pf with _ -> ());
      ok
    with _ ->
      (try Sys.remove pf with _ -> ());
      false
  end else false

(* ── Stale port-forward detection ───────────────────────────────────────── *)

(** Extract the first occurrence of [prefix] followed by decimal digits in
    [s], returning the digits as a string.  Returns [""] if not found. *)
let extract_after_prefix s prefix =
  let pl = String.length prefix and sl = String.length s in
  let rec go i =
    if i + pl > sl then ""
    else if String.sub s i pl = prefix then begin
      let j = ref (i + pl) in
      while !j < sl && s.[!j] >= '0' && s.[!j] <= '9' do incr j done;
      if !j > i + pl then String.sub s (i + pl) (!j - (i + pl))
      else go (i + 1)
    end
    else go (i + 1)
  in
  go 0

(** Find the PID that owns [local_port] using [ss].  Returns [Some pid] or
    [None] if the port is free / the lookup fails. *)
let pid_owning_port local_port =
  let tmp = Filename.temp_file "sun-ss-" ".tmp" in
  ignore (Sys.command
    (Printf.sprintf "ss -tlnp 'sport = :%d' > %s 2>/dev/null" local_port (Filename.quote tmp)));
  let ic = open_in tmp in
  let content = In_channel.input_all ic in
  close_in ic;
  (try Sys.remove tmp with _ -> ());
  let digits = extract_after_prefix content "pid=" in
  if digits = "" then None
  else (try Some (int_of_string digits) with _ -> None)

(** Parse a null-delimited /proc/<pid>/cmdline into a string list. *)
let read_proc_cmdline pid =
  let path = Printf.sprintf "/proc/%d/cmdline" pid in
  try
    let ic = open_in path in
    let raw = In_channel.input_all ic in
    close_in ic;
    List.filter (fun s -> s <> "") (String.split_on_char '\x00' raw)
  with _ ->
    let tmp = Filename.temp_file "sun-ps-" ".tmp" in
    ignore (Sys.command
      (Printf.sprintf "ps -p %d -o args= > %s 2>/dev/null" pid (Filename.quote tmp)));
    let ic = open_in tmp in
    let s = String.trim (In_channel.input_all ic) in
    close_in ic;
    (try Sys.remove tmp with _ -> ());
    String.split_on_char ' ' s

(** Parse the arg list from a [kubectl port-forward -n <ns> svc/<svc> ...]
    invocation.  Returns [(namespace, service)] or raises [Not_found]. *)
let parse_kubectl_pf_args args =
  let rec find_ns = function
    | "-n" :: ns :: _ -> ns
    | _ :: rest -> find_ns rest
    | [] -> raise Not_found
  in
  let ns = find_ns args in
  let svc =
    List.find_map (fun a ->
      if String.length a > 4 && String.sub a 0 4 = "svc/" then
        Some (String.sub a 4 (String.length a - 4))
      else None
    ) args
  in
  match svc with
  | Some s -> (ns, s)
  | None -> raise Not_found

(** Check whether [local_port] is bound by a stale Sun-managed kubectl
    port-forward pointing at a different namespace or service than the one we
    are about to start.  Returns [Some (pid, old_namespace, old_service)] when
    a stale forward is detected, [None] otherwise. *)
let detect_stale_port_forward local_port target_namespace target_service =
  match pid_owning_port local_port with
  | None -> None
  | Some pid ->
    let args = read_proc_cmdline pid in
    let is_kubectl =
      match args with
      | prog :: _ ->
        let base = Filename.basename prog in
        base = "kubectl" || base = "kubectl.exe"
      | [] -> false
    in
    if not is_kubectl then None
    else begin
      let has_pf = List.exists (fun a -> a = "port-forward") args in
      if not has_pf then None
      else begin
        match (try Some (parse_kubectl_pf_args args) with Not_found -> None) with
        | None -> None
        | Some (old_ns, old_svc) ->
          if old_ns <> target_namespace || old_svc <> target_service then
            Some (pid, old_ns, old_svc)
          else
            None
      end
    end
