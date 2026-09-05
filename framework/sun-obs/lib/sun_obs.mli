(** Sun's app-facing observability facade.

    [Obs_eio] stays the neutral event/backend core; this module owns Sun's
    env conventions (which backends to wire up, from what env vars),
    provider bootstrap (Loki/Prometheus/Tempo composed together), and the
    ergonomic logging/metrics/tracing methods generated apps and app
    handlers call. Generated code should depend on [sun_obs], not directly
    on [obs-loki-eio]/[obs-prometheus-eio]/[obs-tempo-eio], unless it is
    intentionally doing provider-specific work.

    {[
      let obs = Sun_obs.of_env ~net:env#net ~clock:env#clock
                  ~mono_clock:env#mono_clock ~service:"payments-charge-svc"
                  ~context:[("team", "payments")] () in
      Sun_obs.log_info obs "starting up";
      Sun_obs.with_span obs "handle_charge" (fun sp ->
        Sun_obs.log sp Sun_obs.Info "charging customer";
        ...)
    ]} *)

type t

type level = Obs_eio.level = Debug | Info | Warn | Error
type span = Obs_eio.span

val of_env
  :  net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> mono_clock:_ Eio.Time.Mono.t
  -> service:string
  -> ?context:(string * string) list
      (** Ambient context applied once via {!Obs_eio.with_context} — e.g.
          [team]/[domain] labels. Every key here is also promoted to a Loki
          stream label (see [obs-loki-eio]'s [label_names]), so keep this
          low-cardinality: team/domain/env, not per-request identifiers.
          Default: []. *)
  -> unit
  -> t
(** Reads [LOKI_URL] and [TEMPO_URL] from the environment and composes
    whichever backends are configured: a Prometheus backend is always
    present; Loki is added when [LOKI_URL] is a non-empty env var, Tempo
    when [TEMPO_URL] is. Logs fall back to stdout when [LOKI_URL] is unset
    (Sun's local-dev default — see the top-level CLAUDE.md's "dev mirrors
    prod" principle: the same [of_env] call works unmodified against
    `sun dev up`'s real Loki/Tempo instances once those env vars are set by
    the platform). *)

val log_debug : t -> ?fields:(string * string) list -> string -> unit
val log_info  : t -> ?fields:(string * string) list -> string -> unit
val log_warn  : t -> ?fields:(string * string) list -> string -> unit
val log_error : t -> ?fields:(string * string) list -> string -> unit
(** Each opens and immediately closes its own span (like
    {!Obs_eio.log_standalone}) — use {!with_span} instead when several log
    calls or a duration belong to the same unit of work. *)

val with_span : t -> ?parent:Obs_trace.t -> string -> (span -> 'a) -> 'a
(** Opens a span, runs the callback, closes the span on every exit path —
    see {!Obs_eio.with_span} for the full contract (this is that function,
    under Sun's facade). *)

val log : span -> level -> ?fields:(string * string) list -> string -> unit
(** Log within an open {!with_span} callback — see {!Obs_eio.log}. *)

val counter
  :  t -> name:string -> help:string -> label_names:string list -> Obs_eio.counter_fn
val gauge
  :  t -> name:string -> help:string -> label_names:string list -> Obs_eio.gauge_fn
val histogram
  :  t -> name:string -> help:string -> label_names:string list -> Obs_eio.histogram_fn
(** Register a metric family and get back an emitter — call once at
    startup, then call the returned function per event. Same
    register-once/use-emitter contract as {!Obs_eio.register_counter}/
    {!Obs_eio.register_gauge}/{!Obs_eio.register_histogram}, which these
    forward to directly. *)

val with_context : t -> (string * string) list -> t
(** Derive a handle with additional ambient context — see
    {!Obs_eio.with_context}. Does not retroactively promote the new keys to
    Loki stream labels; pass everything you want promoted to {!of_env}'s
    [?context] up front. *)

(** {2 Framework primitive bridges}

    These exist for [sun-svc]/[sun-worker]/[sun-fn]'s own [run] functions,
    which each still take a lower-level [Obs_eio.t]/renderer pair directly
    (see each primitive's [.mli]) rather than a [Sun_obs.t] — not for
    application code, which should use the functions above instead. *)

val obs_eio : t -> Obs_eio.t
(** For [sun-svc]/[sun-worker]'s [?ot] parameter. *)

val metrics_renderer : t -> unit -> string
(** For [sun-svc]/[sun-worker]'s [?metrics_renderer] parameter — the
    Prometheus text-exposition renderer, regardless of which other backends
    are composed in. *)

val backend_and_renderer : t -> Obs_eio.backend * (unit -> string)
(** For [sun-fn]'s [?backend] override — the full composed backend (every
    configured provider fanned out together, not Prometheus alone) paired
    with the same renderer as {!metrics_renderer}, matching the shape
    [Obs_prometheus.create] returns. *)
