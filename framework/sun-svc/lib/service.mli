module type HANDLER = sig
  val routes : Route.t list
end

module Make (H : HANDLER) : sig
  val run
    :  env:< net: _ Eio.Net.t; clock: _ Eio.Time.clock; .. >
    -> ?port:int
    -> ?metrics_renderer:(unit -> string)
    (** Renderer for the built-in [/metrics] endpoint.
        Typically the second return value of [Obs_prometheus.create ()]. *)
    -> ?metrics_auth:Auth.level
    -> ?ot:Obs.t
    (** Observability handle for per-request metrics and tracing.
        When provided, [sun_svc_requests_total] and
        [sun_svc_request_duration_seconds] are emitted automatically. *)
    -> ?max_body_bytes:int
    -> ?drain_timeout_s:float
    -> ?on_listen:(int -> unit)
    -> unit
    -> unit
end

val run
  :  Route.t list
  -> env:< net: _ Eio.Net.t; clock: _ Eio.Time.clock; .. >
  -> ?port:int
  -> ?metrics_renderer:(unit -> string)
  -> ?metrics_auth:Auth.level
  -> ?ot:Obs.t
  -> ?max_body_bytes:int
  -> ?drain_timeout_s:float
  -> ?on_listen:(int -> unit)
  -> unit
  -> unit
(** Functional alternative to [Make(H).run]. Equivalent to
    [Make(struct let routes = routes end).run]. Use when routes are defined
    inline or captured from a closure, avoiding the module boilerplate. *)
