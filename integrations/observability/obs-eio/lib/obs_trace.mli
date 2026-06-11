(** W3C-compatible OpenTelemetry trace context. *)

type t = {
  trace_id    : int64 * int64;  (** 128-bit trace identifier *)
  span_id     : int64;          (** 64-bit span identifier *)
  trace_flags : char;           (** bit 0 = sampled *)
  baggage     : (string * string) list;
}

val generate   : unit -> t
(** Create a new root context with a fresh random trace_id and span_id.
    Call [Random.self_init ()] at program startup for non-deterministic IDs. *)

val child_span : t -> t
(** Derive a child span: inherits trace_id, generates a new span_id. *)

val to_traceparent : t -> string
(** Serialize to W3C traceparent: ["00-{32hex}-{16hex}-{02hex}"] *)

val of_traceparent : string -> t option
(** Parse a W3C traceparent header value. Returns [None] if malformed. *)

val extract_from_headers : (string * string) list -> t option
(** Look up ["traceparent"] in a header list and parse it. *)

val inject_to_headers : t -> (string * string) list -> (string * string) list
(** Set or replace ["traceparent"] in a header list. *)
