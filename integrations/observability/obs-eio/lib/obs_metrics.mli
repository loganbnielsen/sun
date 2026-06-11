(** Typed emitter functions returned by [Obs.register_*].
    Each is the result of a registration call and carries the metric name,
    help string, and declared label names internally. *)

type counter_fn   = ?labels:(string * string) list -> int   -> unit
type gauge_fn     = ?labels:(string * string) list -> float -> unit
type histogram_fn = ?labels:(string * string) list -> float -> unit
