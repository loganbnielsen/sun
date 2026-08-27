(** Loki HTTP push backend for obs-eio.

    Emits one structured JSON log line per [Obs.log] call made within a span,
    plus one span-completion line for spans with no [Obs.log] calls. Lines
    are pushed synchronously to Loki's push API when the span closes — one
    HTTP POST per span, which can block the closing fiber up to the 5s
    request timeout. There is no buffering, batching, or backpressure; this
    is the 0.1 behavior, not a temporary gap. If Loki is unreachable or
    returns a non-2xx response, the error is printed to stderr and the call
    returns normally — the observability backend never crashes or blocks the
    application beyond that one push. [https://] URLs are supported via the
    system CA bundle (see [error_to_string]'s [`No_system_ca_bundle]).

    All log lines in a span share one timestamp, taken when the span closes
    — not a per-entry timestamp. Long spans or repeated identical lines can
    therefore have misleading ordering or dedup behavior in Loki.

    Each pushed value is the Loki 2.x/3.x-compatible 2-element
    [\[timestamp_ns, log_line\]] form, not Loki 3's 3-element structured
    metadata — [trace_id]/[span_id] are carried as logfmt fields in the line
    body instead (query with [| logfmt] in LogQL), so lines stay searchable
    on Loki 2.x deployments (e.g. the loki-stack Helm chart) too.

    Stream labels are always [{service}] plus any context fields selected by
    [label_names].  Keep labels low-cardinality (env, region, tier);
    high-cardinality values (request_id, payment_id) belong in the log line.

    {[
      let loki =
        Obs_loki.create ~net:env#net ~clock:env#clock
          ~url:"http://localhost:3100"
          ~label_names:[Obs_loki.stream_label "env";
                        Obs_loki.stream_label "region"] () in
      let ot =
        Obs.create ~service:"payments-worker"
          ~mono_clock:env#mono_clock ~backend:loki in
      let ot = Obs.with_context ot [("env", "prod"); ("region", "us-east-1")] in
      Obs.with_span ot "payment.process" (fun sp ->
        Obs.log sp Obs.Info ~fields:[("payment_id", "p_123")] "processing")
    ]} *)

type stream_label = Obs.label_name
(** Validated context field name that can be promoted to a Loki stream label. *)

val stream_label : string -> stream_label
(** [stream_label name] validates [name] with [Obs.label_name] and returns a
    typed Loki stream-label selector. Raises [Invalid_argument] on invalid
    names. *)

val create
  :  net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> url:string
     (** Base URL of the Loki instance, e.g. ["http://localhost:3100"].
         The push path [/loki/api/v1/push] is appended automatically. *)
  -> ?label_names:stream_label list
     (** Context field names to promote to Loki stream labels. Missing context
         fields are logged to stderr and omitted. [service] is always included.
         Default: [[]]. *)
  -> unit
  -> Obs.backend
