(** The Lambda Runtime API long-poll loop. No dependency on [aws-eio] — the
    Runtime API is a local, unsigned HTTP sidecar
    ([AWS_LAMBDA_RUNTIME_API] points at a loopback address the Lambda
    execution environment provides), not a signed AWS API call. Uses
    [Cohttp_eio.Client] directly, matching [obs-loki-eio]/
    [obs-prometheus-eio]'s own precedent for plain HTTP where there's no
    SigV4 wire-byte-encoding concern. *)

type invocation = {
  request_id : string;
  deadline_ms : int64;
  invoked_function_arn : string;
  trace_id : string option;
  payload : string;  (** raw JSON event body — {!Lambda_event} parses common shapes *)
}

val runtime_api_base : unit -> (string, string) result
(** Reads [AWS_LAMBDA_RUNTIME_API]. [Error] if unset — calling this outside a
    real Lambda execution environment (or a local Runtime Interface
    Emulator) is a configuration error, not something to default around. *)

val next_invocation : net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string -> (invocation, string) result
(** [GET {base}/2018-06-01/runtime/invocation/next]. A real long-poll — this
    can block for minutes waiting for the next event. *)

val respond :
  net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string -> request_id:string -> body:string -> (unit, string) result

val respond_error :
  net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string -> request_id:string ->
  error_message:string -> error_type:string -> (unit, string) result

val init_error :
  net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string ->
  error_message:string -> error_type:string -> (unit, string) result
(** [POST {base}/2018-06-01/runtime/init/error] — for a failure before the
    loop below ever starts, distinct from a per-invocation error. *)

(** {2 Exposed for testing} *)

val invocation_of_headers : headers:Http.Header.t -> payload:string -> (invocation, string) result
(** [next_invocation]'s pure header-parsing step. *)

val run_loop :
  net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string ->
  handler:(invocation -> (string, string) result) -> unit
(** Loops forever: [next_invocation], run [handler], [respond]/
    [respond_error]. A handler exception is caught and reported via
    [respond_error] rather than propagating — one bad invocation must not
    crash the whole warm execution environment for every future invocation.
    A transient [next_invocation] failure is logged to stderr and retried,
    not fatal, for the same reason. *)
