(** Observability handle — distributed tracing, structured logging, and metrics
    in a single capability-passed value.

    Create once at service startup, then pass [ot] into workers and handlers.
    Use [with_context] to derive a scoped copy with per-request or per-message
    fields; the original is unchanged and safe to share across fibers.

    {[
      let ot = Obs.create ~service:"payments-worker"
                 ~mono_clock:env#mono_clock ~backend:Obs.stdout in
      let ot = Obs.with_context ot [("env", "prod")] in

      let msgs_processed = Obs.register_counter ot
        ~name:"kafka_messages_processed_total"
        ~help:"Total messages processed"
        ~label_names:["topic"] in

      let handle_message msg =
        let parent = Obs_trace.extract_from_headers msg.headers in
        Obs.with_span ot ?parent "payment.process" (fun sp ->
          Obs.log sp Obs.Info ~fields:[("payment_id", msg.id)] "processing";
          msgs_processed ~labels:[("topic", "payments")] 1)
      in
      ignore handle_message
    ]} *)

(* ------------------------------------------------------------------ *)
(* Backend                                                             *)
(* ------------------------------------------------------------------ *)

type level = Debug | Info | Warn | Error

type log_entry = {
  level   : level;
  message : string;
  fields  : (string * string) list;
}

type span_event = {
  trace_ctx : Obs_trace.t;
  name      : string;
  service   : string;
  start_ns  : int64;  (** monotonic nanoseconds from [Eio.Time.Mono.now] *)
  end_ns    : int64;
  status    : [ `Ok | `Error of string ];
  fields    : (string * string) list;
  (** Span-level fields reserved for backend-specific metadata. *)
  log_entries : log_entry list;
  (** Structured log entries from [log] calls within this span.
      Entries appear in call order. *)
  context   : (string * string) list;
  (** Ambient context from [with_context] at the time the span was opened.
      Backends use this for stream labels (Loki) or resource attributes (OTLP). *)
}

type metric_event = {
  name    : string;
  help    : string;
  kind    : [ `Counter of int | `Gauge of float | `Histogram of float ];
  labels  : (string * string) list;  (** call-site labels *)
  context : (string * string) list;  (** ambient context from [with_context] *)
  service : string;
}

type backend = {
  emit_span   : span_event   -> unit;
  emit_metric : metric_event -> unit;
}
(** A caller-supplied backend may raise; callers of [with_span], [log_t], and
    the [register_*] emitters never see that exception — it is caught and
    logged to stderr, so a broken backend cannot crash application code. *)

val noop    : backend
(** Drops all events. Use in tests and CI. *)

val stdout  : backend
(** Pretty-prints spans and metrics to stdout. Use for local development. *)

val compose : backend -> backend -> backend
(** Fan-out to two backends, e.g. [compose prometheus_backend loki_backend].
    Each backend's [emit_span]/[emit_metric] is called independently: if one
    raises, the exception is logged to stderr and the other backend still
    receives the event. *)

(* ------------------------------------------------------------------ *)
(* Handle                                                              *)
(* ------------------------------------------------------------------ *)

type t
type span

val create
  :  service:string
  -> mono_clock:_ Eio.Time.Mono.t
  -> backend:backend
  -> t
(** [create ~service ~mono_clock ~backend] creates an observability handle.
    [mono_clock] is used for span duration measurement only — pass [env#mono_clock].
    Wall clock is never used for span timestamps. *)

(* ------------------------------------------------------------------ *)
(* Context                                                             *)
(* ------------------------------------------------------------------ *)

val with_context : t -> (string * string) list -> t
(** [with_context ot fields] returns a new handle with [fields] merged into the
    ambient context. Fields in [fields] override existing keys with the same name.
    The original [ot] is unchanged — safe to pass to concurrent fibers. *)

(* ------------------------------------------------------------------ *)
(* Spans & logging                                                     *)
(* ------------------------------------------------------------------ *)

val with_span : t -> ?parent:Obs_trace.t -> string -> (span -> 'a) -> 'a
(** [with_span ot ?parent name f] opens a span, runs [f span], then closes it.
    If [f] raises, the span closes with [Error] status and the exception propagates.
    [parent] is typically from [Obs_trace.extract_from_headers] on the incoming
    Kafka message or HTTP request — linking this span to the upstream trace. *)

val log : span -> level -> ?fields:(string * string) list -> string -> unit
(** [log span level ?fields message] records a structured log entry inside an
    active span. Entries are buffered and included in [span_event.log_entries]
    when the span closes. The span's trace_id and span_id are attached
    automatically. *)

val log_t : t -> level -> ?fields:(string * string) list -> string -> unit
(** [log_t ot level ?fields message] logs without requiring an explicit span.
    Equivalent to [with_span ot "log" (fun sp -> log sp level ?fields message)].
    Use when you want structured logging but don't need an explicit span name. *)

val current_trace_ctx : span -> Obs_trace.t
(** [current_trace_ctx span] returns the active [Obs_trace.t] for an open span.
    Use with [Obs_trace.inject_to_headers] to propagate the trace into outgoing
    Kafka messages or HTTP requests, linking the downstream span to this trace. *)

(* ------------------------------------------------------------------ *)
(* Metrics                                                             *)
(* ------------------------------------------------------------------ *)

val metric_name : string -> string
(** [metric_name name] validates [name] against Prometheus metric naming
    rules and returns it unchanged. Raises [Invalid_argument] on invalid
    names. *)

type label_name = private string
(** Validated Prometheus label name. Construct with [label_name]. *)

val label_name : string -> label_name
(** [label_name name] validates [name] against Prometheus label naming rules
    and returns it unchanged. Raises [Invalid_argument] on invalid names. *)

val label_name_to_string : label_name -> string
(** [label_name_to_string name] returns the validated label name as a string. *)

type counter_fn   = ?labels:(string * string) list -> int   -> unit
type gauge_fn     = ?labels:(string * string) list -> float -> unit
type histogram_fn = ?labels:(string * string) list -> float -> unit
(** Typed emitter functions returned by [register_*]. *)

val register_counter
  :  t
  -> name:string
  -> help:string
  -> label_names:string list
  -> counter_fn
(** Register a counter metric family. Returns an emitter function. Call it once
    at startup, then call the returned function per event. [label_names] must
    be unique; emitted labels must match the declared names exactly. The
    emitter raises [Invalid_argument] on a negative delta — Prometheus
    counters are monotonic.
    {[
      let reqs = Obs.register_counter ot ~name:"http_requests_total"
                   ~help:"Total HTTP requests" ~label_names:["method";"status"] in
      reqs ~labels:[("method","POST");("status","200")] 1
    ]} *)

val register_gauge
  :  t
  -> name:string
  -> help:string
  -> label_names:string list
  -> gauge_fn

val register_histogram
  :  t
  -> name:string
  -> help:string
  -> label_names:string list
  -> histogram_fn
(** [label_names] must not include ["le"] — raises [Invalid_argument] if it
    does, since the Prometheus backend synthesizes an ["le"] label per
    bucket sample and a caller-declared one would collide with it.
    Bucket boundaries are backend-defined (e.g. [Obs_prometheus]'s
    [default_bounds]); there is currently no per-metric override. *)

val register_counter_and_histogram
  :  t
  -> counter_name:string
  -> counter_help:string
  -> counter_labels:string list
  -> histogram_name:string
  -> histogram_help:string
  -> histogram_labels:string list
  -> counter_fn * histogram_fn
(** Register a counter and histogram metric family together. Use for framework
    startup paths that always expose a count metric plus a duration metric. *)
