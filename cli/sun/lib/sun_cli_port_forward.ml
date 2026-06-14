type spec = {
  name        : string;
  namespace   : string;
  (* Full kubectl resource target, e.g. "svc/redis" or "pod/redpanda-0". *)
  target      : string;
  local_port  : int;
  remote_port : int;
}

let pid_file ~state_dir name = Printf.sprintf "%s/pf-%s.pid" state_dir name
let log_file name             = Printf.sprintf "/tmp/sun-pf-%s.log" name
let script_file name          = Printf.sprintf "/tmp/sun-pf-%s.sh" name

(* Read /proc/<pid>/cmdline (NUL-separated) or fall back to ps. *)
let read_proc_cmdline pid =
  let path = Printf.sprintf "/proc/%d/cmdline" pid in
  try
    let ic = open_in path in
    let raw = In_channel.input_all ic in
    close_in ic;
    List.filter (fun s -> s <> "") (String.split_on_char '\x00' raw)
  with _ ->
    let tmp = Filename.temp_file "sun-pf-ps-" ".tmp" in
    ignore (Sys.command (Printf.sprintf
      "ps -p %d -o args= > %s 2>/dev/null" pid (Filename.quote tmp)));
    let ic = open_in tmp in
    let s = String.trim (In_channel.input_all ic) in
    close_in ic;
    (try Sys.remove tmp with _ -> ());
    List.filter (fun s -> s <> "") (String.split_on_char ' ' s)

(* True if process [pid] exists (no signal sent). *)
let pid_alive pid =
  Sys.command (Printf.sprintf "kill -0 %d 2>/dev/null" pid) = 0

let ends_with s suffix =
  let sl = String.length s and sfxl = String.length suffix in
  sl >= sfxl && String.sub s (sl - sfxl) sfxl = suffix

(* Check whether our wrapper script for [name] is still running. *)
let is_alive ~state_dir spec =
  let pf = pid_file ~state_dir spec.name in
  if not (Sys.file_exists pf) then false
  else begin
    try
      let ic = open_in pf in
      let pid_s = String.trim (In_channel.input_all ic) in
      close_in ic;
      let pid = int_of_string pid_s in
      let alive = pid_alive pid in
      let args  = if alive then read_proc_cmdline pid else [] in
      let expected_sfx = Printf.sprintf "sun-pf-%s.sh" spec.name in
      let ok = alive && List.exists (fun a -> ends_with a expected_sfx) args in
      if not ok then (try Sys.remove pf with _ -> ());
      ok
    with _ ->
      (try Sys.remove pf with _ -> ());
      false
  end

let start ~state_dir spec =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote state_dir)));
  Printf.printf "  port-forward  %-14s localhost:%d → %s/%s:%d\n%!"
    spec.name spec.local_port spec.namespace spec.target spec.remote_port;
  let sf = script_file spec.name in
  let lf = log_file spec.name in
  let pf = pid_file ~state_dir spec.name in
  let content = Printf.sprintf
    "#!/bin/sh\necho $$ > %s\nwhile true; do\n  kubectl port-forward -n %s %s %d:%d </dev/null >> %s 2>&1\n  sleep 1\ndone\n"
    (Filename.quote pf)
    (Filename.quote spec.namespace) (Filename.quote spec.target)
    spec.local_port spec.remote_port
    (Filename.quote lf)
  in
  let oc = open_out sf in
  output_string oc content;
  close_out oc;
  ignore (Sys.command (Printf.sprintf "chmod +x %s" (Filename.quote sf)));
  (* setsid puts the loop in its own session so it outlives this process. *)
  ignore (Sys.command (Printf.sprintf
    "setsid %s </dev/null >/dev/null 2>&1 &" (Filename.quote sf)))

let stop ~state_dir spec =
  let pf = pid_file ~state_dir spec.name in
  if Sys.file_exists pf then begin
    (try
      let ic = open_in pf in
      let pid_s = String.trim (In_channel.input_all ic) in
      close_in ic;
      (match int_of_string_opt pid_s with
       | Some pid -> ignore (Sys.command (Printf.sprintf "kill %d 2>/dev/null" pid))
       | None -> ());
      Sys.remove pf
    with _ -> ())
  end

let stop_all ~state_dir =
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
           | Some pid -> ignore (Sys.command (Printf.sprintf "kill %d 2>/dev/null" pid))
           | None -> ());
          Sys.remove path
        with _ -> ())
      end
    ) entries
  end

(* ── Stale port-forward detection ─────────────────────────────────────────── *)

(* Extract the first decimal-digit run that follows [prefix] in [s]. *)
let extract_after_prefix s prefix =
  let pl = String.length prefix and sl = String.length s in
  let rec go i =
    if i + pl > sl then ""
    else if String.sub s i pl = prefix then begin
      let j = ref (i + pl) in
      while !j < sl && s.[!j] >= '0' && s.[!j] <= '9' do incr j done;
      if !j > i + pl then String.sub s (i + pl) (!j - (i + pl))
      else go (i + 1)
    end else go (i + 1)
  in go 0

(* Find the PID that has [local_port] bound via ss.  Returns None if free or lookup fails. *)
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

(* Parse -n <ns> and the first svc/... or pod/... arg from a kubectl port-forward cmdline. *)
let parse_kubectl_pf_target args =
  let rec find_ns = function
    | "-n" :: ns :: _ -> ns
    | _ :: rest -> find_ns rest
    | [] -> raise Not_found
  in
  let ns = find_ns args in
  let target =
    List.find_opt (fun a ->
      (String.length a > 4 && (String.sub a 0 4 = "svc/" || String.sub a 0 4 = "pod/"))
    ) args
  in
  match target with
  | Some t -> (ns, t)
  | None   -> raise Not_found

(** [detect_stale ~state_dir spec] checks whether [spec.local_port] is already
    bound by a stale Sun-managed kubectl port-forward pointing at a different
    namespace or target.  Returns [Some (pid, old_ns, old_target)] when a stale
    forward is found, [None] when the port is free or the owner is not kubectl. *)
let detect_stale ~state_dir:_ spec =
  match pid_owning_port spec.local_port with
  | None -> None
  | Some pid ->
    let args = read_proc_cmdline pid in
    let is_kubectl =
      match args with
      | prog :: _ ->
        let b = Filename.basename prog in b = "kubectl" || b = "kubectl.exe"
      | [] -> false
    in
    if not is_kubectl then None
    else if not (List.exists (fun a -> a = "port-forward") args) then None
    else begin
      match (try Some (parse_kubectl_pf_target args) with Not_found -> None) with
      | None -> None
      | Some (old_ns, old_target) ->
        if old_ns <> spec.namespace || old_target <> spec.target
        then Some (pid, old_ns, old_target)
        else None
    end

(* Sleep 200 ms, then check liveness. Prints a warning with log tail if dead.
   Returns true if alive. *)
let liveness_check ~state_dir spec =
  Unix.sleepf 0.2;
  let alive = is_alive ~state_dir spec in
  if not alive then begin
    let lf = log_file spec.name in
    let tail =
      try
        let ic = open_in lf in
        let content = In_channel.input_all ic in
        close_in ic;
        let lines = String.split_on_char '\n' (String.trim content) in
        let n = List.length lines in
        let drop k lst =
          let rec go i = function [] -> [] | _ :: t -> if i = 0 then t else go (i-1) t
          in go k lst
        in
        let tail = if n <= 5 then lines else drop (n - 5) lines in
        String.concat "\n" tail
      with _ -> ""
    in
    Printf.printf
      "  warning: port-forward for %s failed (port %d may be in use).\n"
      spec.name spec.local_port;
    Printf.printf "           See %s for details.\n" lf;
    if tail <> "" then
      Printf.printf "           Last log lines:\n             %s\n"
        (String.concat "\n             " (String.split_on_char '\n' tail));
    Printf.printf "           Run: kill $(lsof -ti:%d) && sun up\n%!" spec.local_port
  end;
  alive
