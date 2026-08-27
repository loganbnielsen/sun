(** W3C-compatible OpenTelemetry trace context. *)

type t = {
  trace_id    : int64 * int64;  (** 128-bit trace identifier *)
  span_id     : int64;          (** 64-bit span identifier *)
  trace_flags : char;           (** bit 0 = sampled *)
  baggage     : (string * string) list;
}

val generate   : unit -> t
(** Create a new root context with a fresh random trace_id and span_id, from
    a self-seeded PRNG state private to this module — no caller-side
    [Random.self_init ()] needed. Not cryptographically strong; sufficient
    for correlation and collision-avoidance, not for anything security-
    sensitive. *)

val child_span : t -> t
(** Derive a child span: inherits trace_id, generates a new span_id. *)

val traceparent_header : string
(** Canonical W3C traceparent header name. *)

val to_traceparent : t -> string
(** Serialize to W3C traceparent: ["00-{32hex}-{16hex}-{02hex}"] *)

val of_traceparent : string -> t option
(** Parse a W3C traceparent header value. Returns [None] if malformed. *)

val extract_from_headers : (string * string) list -> t option
(** Look up {!traceparent_header} in a header list case-insensitively and parse it. *)

val inject_to_headers : t -> (string * string) list -> (string * string) list
(** Set or replace {!traceparent_header} in a header list case-insensitively. *)
