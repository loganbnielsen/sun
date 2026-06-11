module type FN = sig
  val schedule : string
  (** Cron expression — v1 trigger, e.g. ["0 * * * *"] for hourly. *)

  val run : unit -> (unit, string) result
  (** The function body. Called once per invocation; must return. *)
end

module Make (F : FN) : sig
  val run
    :  env:< net       : _ Eio.Net.t
           ; clock     : _ Eio.Time.clock
           ; mono_clock: _ Eio.Time.Mono.t
           ; .. >
    -> ?pushgateway_url:string
    (** Pushgateway base URL, e.g. "http://pushgateway:9091".
        If absent, metrics are recorded in-process but not pushed. *)
    -> ?job:string
    (** Pushgateway job label. Defaults to [F.schedule]. *)
    -> ?backend:(Obs.backend * (unit -> string))
    (** Override the default [Obs_prometheus.create ()] backend+renderer pair.
        Useful for composing with additional backends (e.g. [Obs.compose]) or
        for inspecting rendered metrics in tests. *)
    -> unit
    -> unit
  (** Run [F.run ()], record metrics, push to Pushgateway if configured,
      then exit.  On [Error msg] raises [Failure msg] (caller should
      [exit 1]).  On SIGTERM/SIGINT exits with code 130. *)
end
