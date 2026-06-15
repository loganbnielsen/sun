(** Shared port-forward management for [sun up] and [sun dev up/down/status].

    All state is kept under an absolute XDG-compliant directory so that
    port-forward PID files are shared across invocations regardless of the
    working directory from which [sun] is called. *)

(** Absolute path to the directory that holds PID files and log metadata. *)
val state_dir : string

(** [pid_file name] returns the absolute path of the PID file for a
    port-forward named [name]. *)
val pid_file : string -> string

(** Ensure [state_dir] exists (creates it if absent). *)
val ensure_state_dir : unit -> unit

(** [start ~name ~namespace ~target ~local_port ~remote_port] writes a
    self-restarting wrapper script and backgrounds it in a new session.  The
    wrapper re-runs [kubectl port-forward] whenever it exits so the forward
    stays live across pod rollouts.

    [target] is the full kubectl resource reference, e.g. ["svc/redpanda"] or
    ["pod/redpanda-0"]. *)
val start :
  name:string ->
  namespace:string ->
  target:string ->
  local_port:int ->
  remote_port:int ->
  unit

(** [stop_all ()] kills every background port-forward whose PID file lives in
    [state_dir] and removes the PID files. *)
val stop_all : unit -> unit

(** [check_liveness ~name ~local_port] sleeps 200 ms (to let the wrapper write
    its PID file), then checks whether the background process is still alive.
    Returns [true] when alive.  When dead, prints a diagnostic message with the
    log path and a kill hint, then returns [false]. *)
val check_liveness : name:string -> local_port:int -> bool

(** [is_running ~name] returns [true] when the PID file for [name] exists and
    the recorded process is alive and matches the expected wrapper script. *)
val is_running : name:string -> bool

(** [detect_stale local_port target_namespace target_service] checks whether
    [local_port] is already bound by a [kubectl port-forward] that targets a
    *different* namespace or service than [target_namespace]/[target_service].

    Returns [Some (pid, old_namespace, old_service)] when a stale forward is
    detected, [None] otherwise. *)
val detect_stale :
  int -> string -> string -> (int * string * string) option
