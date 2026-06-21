type spec = {
  name        : string;
  namespace   : string;
  target      : string;
  local_port  : int;
  remote_port : int;
}

(* ------------------------------------------------------------------ *)
(* Internal helpers                                                     *)
(* ------------------------------------------------------------------ *)


let read_cmdline pid =
  let tmp = Filename.temp_file "sun-ps-" ".tmp" in
  ignore (Sys.command
    (Printf.sprintf "ps -p %d -o args= > %s 2>/dev/null" pid (Filename.quote tmp)));
  let ic = open_in tmp in
  let s = String.trim (In_channel.input_all ic) in
  close_in ic;
  (try Sys.remove tmp with _ -> ());
  s

let read_last_lines path n =
  try
    let ic = open_in path in
    let content = In_channel.input_all ic in
    close_in ic;
    let lines = String.split_on_char '\n' (String.trim content) in
    let total = List.length lines in
    let tail =
      if total <= n then lines
      else
        let rec drop k lst = if k = 0 then lst else drop (k-1) (List.tl lst) in
        drop (total - n) lines
    in
    String.concat "\n" tail
  with _ -> ""

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

(* ------------------------------------------------------------------ *)
(* Public API                                                           *)
(* ------------------------------------------------------------------ *)

let is_running name =
  let pf = Sun_cli_state.pid_file name in
  if Sys.file_exists pf then begin
    let ic = open_in pf in
    let pid_s = String.trim (In_channel.input_all ic) in
    close_in ic;
    try
      let pid = int_of_string pid_s in
      let alive = Sys.command (Printf.sprintf "kill -0 %d 2>/dev/null" pid) = 0 in
      let args = if alive then read_cmdline pid else "" in
      let ok = alive && Sun_cli_shell.string_contains ~needle:(Printf.sprintf "sun-pf-%s.sh" name) args in
      if not ok then (try Sys.remove pf with _ -> ());
      ok
    with _ ->
      (try Sys.remove pf with _ -> ());
      false
  end else false

(** Write a self-restarting wrapper script and background it in a new session.
    On pod rollout, kubectl exits; the loop restarts it within ~1 s so the
    port-forward stays live across deploys without manual intervention. *)
let start (pf : spec) =
  Sun_cli_state.ensure ();
  let sf = Sun_cli_state.script_file pf.name in
  let lf = Sun_cli_state.log_file pf.name in
  let pf_file = Sun_cli_state.pid_file pf.name in
  let content = Printf.sprintf
    "#!/bin/sh\necho $$ > %s\nwhile true; do\n  kubectl port-forward -n %s %s %d:%d </dev/null >> %s 2>&1\n  sleep 1\ndone\n"
    (Filename.quote pf_file)
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

let stop_all () =
  if Sys.file_exists Sun_cli_state.dir then begin
    let entries = try Sys.readdir Sun_cli_state.dir with _ -> [||] in
    Array.iter (fun f ->
      if Filename.check_suffix f ".pid" then begin
        let path = Printf.sprintf "%s/%s" Sun_cli_state.dir f in
        (try
          let ic = open_in path in
          let pid_s = String.trim (In_channel.input_all ic) in
          close_in ic;
          (match int_of_string_opt pid_s with
           | Some pid ->
             ignore (Sun_cli_shell.run_cmd ~echo:false
               (Printf.sprintf "kill %d 2>/dev/null" pid))
           | None -> ());
          Sys.remove path
        with _ -> ())
      end
    ) entries
  end

(** Sleep 200 ms, then check whether the port-forward process for [name] is
    still alive.  When dead, prints a warning with the log path and a
    suggested remediation command.  Returns [true] if alive. *)
let check_alive ~name ~local_port =
  Unix.sleepf 0.2;
  let pf = Sun_cli_state.pid_file name in
  let alive =
    if Sys.file_exists pf then begin
      try
        let ic = open_in pf in
        let pid_s = String.trim (In_channel.input_all ic) in
        close_in ic;
        let pid = int_of_string pid_s in
        (try Unix.kill pid 0; true
         with Unix.Unix_error (Unix.ESRCH, _, _) -> false
            | Unix.Unix_error _ -> true)
      with _ -> false
    end else false
  in
  if not alive then begin
    let lf = Sun_cli_state.log_file name in
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

(** Check whether [local_port] is bound by a stale Sun-managed kubectl
    port-forward pointing at a different namespace or [target] than the one
    we are about to start.  When detected, kills the stale process and prints
    a notice.  Returns [true] if a stale was found and killed. *)
let detect_stale ~local_port ~namespace ~target =
  match pid_owning_port local_port with
  | None -> false
  | Some pid ->
    let args = read_proc_cmdline pid in
    let is_kubectl =
      match args with
      | prog :: _ ->
        let base = Filename.basename prog in
        base = "kubectl" || base = "kubectl.exe"
      | [] -> false
    in
    if not is_kubectl then false
    else begin
      let has_pf = List.exists (fun a -> a = "port-forward") args in
      if not has_pf then false
      else begin
        match (try Some (parse_kubectl_pf_args args) with Not_found -> None) with
        | None -> false
        | Some (old_ns, old_svc) ->
          if old_ns <> namespace || ("svc/" ^ old_svc) <> target then begin
            Printf.printf
              "  [sun up] replacing stale port-forward for %s/%s on port %d\n%!"
              old_ns old_svc local_port;
            (try Unix.kill pid Sys.sigterm
             with Unix.Unix_error _ -> ());
            true
          end else
            false
      end
    end
