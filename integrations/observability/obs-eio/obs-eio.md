# obs-eio

Observability library for Sun — distributed tracing, structured logging, and metrics in a single capability-passed handle. Designed for OCaml 5 / Eio concurrency, with swappable backends (noop, stdout, Prometheus + Loki, Datadog).

A small Eio-native observability event model with built-in backend adapters, not a
replacement for every OCaml observability package — see `obs-eio-prometheus`'s notes on
`prometheus`/`prometheus-eio` for how this positions against existing packages.

## Package Structure

```
integrations/observability/
  obs-eio/
    lib/
      obs_trace.ml/.mli   ← W3C trace context, header propagation
      obs.ml/.mli         ← handle, spans, logging, metrics, and the emitter
                             function type aliases (counter_fn/gauge_fn/histogram_fn)
    test/
      test_obs.ml
```

Concrete backend packages: `obs-eio-loki`, `obs-eio-prometheus`, `obs-eio-datadog` (backlog).

## Public API

### `Obs_trace`

```ocaml
type t = {
  trace_id    : int64 * int64;
  span_id     : int64;
  trace_flags : char;
  baggage     : (string * string) list;
}

val generate         : unit -> t               (* new root context *)
val child_span       : t -> t                  (* same trace_id, new span_id *)
val to_traceparent   : t -> string             (* W3C "00-{32hex}-{16hex}-{02hex}" *)
val of_traceparent   : string -> t option
val extract_from_headers : (string * string) list -> t option
val inject_to_headers    : t -> (string * string) list -> (string * string) list
```

`generate`'s randomness is a self-seeded PRNG state private to this module — no caller
`Random.self_init ()` call needed, and no risk of every process sharing the stdlib
`Random` module's fixed default seed. Not cryptographically strong; fine for correlation
and collision-avoidance, not for anything security-sensitive.

### `Obs` — metric emitter types

```ocaml
type counter_fn   = ?labels:(string * string) list -> int   -> unit
type gauge_fn     = ?labels:(string * string) list -> float -> unit
type histogram_fn = ?labels:(string * string) list -> float -> unit
```

### `Obs`

```ocaml
type level = Debug | Info | Warn | Error

type log_entry = {
  level   : level;
  message : string;
  fields  : (string * string) list;
}

type span_event = {
  trace_ctx   : Obs_trace.t;
  name        : string;
  service     : string;
  start_ns    : int64;
  end_ns      : int64;
  status      : [ `Ok | `Error of string ];
  fields      : (string * string) list;
  log_entries : log_entry list;
  context     : (string * string) list;
}

type backend = {
  emit_span   : span_event   -> unit;
  emit_metric : metric_event -> unit;
}

val noop    : backend   (* drops everything *)
val stdout  : backend   (* pretty-prints to stdout *)
val compose : backend -> backend -> backend

val create
  :  service:string
  -> mono_clock:_ Eio.Time.Mono.t
  -> backend:backend
  -> t

val with_context : t -> (string * string) list -> t

val with_span : t -> ?parent:Obs_trace.t -> string -> (span -> 'a) -> 'a

val log             : span -> level -> ?fields:(string * string) list -> string -> unit
val current_trace_ctx : span -> Obs_trace.t

val register_counter   : t -> name:string -> help:string -> label_names:string list -> counter_fn
val register_gauge     : t -> name:string -> help:string -> label_names:string list -> gauge_fn
val register_histogram : t -> name:string -> help:string -> label_names:string list -> histogram_fn
```

`register_counter`'s emitter raises `Invalid_argument` on a negative delta — Prometheus
counters are monotonic. `register_histogram` raises `Invalid_argument` if `label_names`
includes `"le"`, since the Prometheus backend synthesizes an `"le"` label per bucket
sample. Bucket boundaries are backend-defined (`obs-eio-prometheus`'s `default_bounds`);
there is no per-metric override.

## Configuration

No configuration. Backends handle their own connection parameters at construction time. The `t` handle is created once at service startup.

## Example Usage

```ocaml
let ot = Obs.create ~service:"payments-worker"
           ~mono_clock:env#mono_clock ~backend:Obs.stdout in
let ot = Obs.with_context ot [("env", "prod"); ("region", "us-east-1")] in

(* Register metrics once at startup *)
let msgs_ok = Obs.register_counter ot
  ~name:"kafka_messages_processed_total"
  ~help:"Total messages processed"
  ~label_names:["topic"; "status"] in

(* Per-message handler *)
let handle raw_msg =
  let parent = Obs_trace.extract_from_headers raw_msg.headers in
  Obs.with_span ot ?parent "payment.process" (fun sp ->
    let ot = Obs.with_context ot [("payment_id", raw_msg.id)] in
    Obs.log sp Obs.Info ~fields:[("amount_cents", "9900")] "processing payment";
    (* ... business logic ... *)
    msgs_ok ~labels:[("topic", "payments"); ("status", "ok")] 1;
    (* propagate trace to downstream Kafka message *)
    let headers = Obs_trace.inject_to_headers (Obs.current_trace_ctx sp) [] in
    ignore (ot, headers))
in
ignore handle
```

## Design Notes

- **Immutable context**: `with_context` returns a new `t`. The original is unchanged, so it is safe to pass the same `ot` to multiple concurrent fibers and derive per-fiber scoped copies.
- **Monotonic time**: `span_event.start_ns` and `end_ns` use `Mtime.to_uint64_ns` on `Eio.Time.Mono.now` — unaffected by NTP corrections.
- **OTel-compatible tracing**: `Obs_trace.t` carries W3C `traceparent`-compatible fields. `extract_from_headers` / `inject_to_headers` connect producers, brokers, and consumers into a single distributed trace.
- **Pre-registered metrics**: `register_counter` / `register_gauge` / `register_histogram` return typed emitter closures. The Prometheus backend uses the registration metadata (name, help, label names) to declare metric families before first emission.
- **Backend composition**: `compose a b` fans out to two backends — use for e.g. `compose prometheus_backend loki_backend`.
- **Backend failure isolation**: a caller-supplied backend may raise; `with_span`, `log_t`, and the `register_*` emitters catch it and log to stderr rather than propagate it, so a broken backend cannot crash application code. `compose` isolates each sibling the same way, so one broken backend cannot also block delivery to the other.

## Out of Scope (this package)

- `obs-eio-loki` — Loki HTTP push backend (separate package, in progress)
- `obs-eio-prometheus` — Prometheus exposition backend (separate package, next)
- `obs-eio-datadog` — Datadog backend (backlog)
- Grafana dashboard templates — Phase 3 (after -svc/-fn)
- Auto-wiring into `-svc` / `-fn` functors — after HTTP service layer lands
- Baggage propagation — `Obs_trace.t.baggage` is preserved across `inject_to_headers` / `extract_from_headers` but not exposed in the v1 API
- Sampling decisions — `trace_flags` is set to `\x01` (sampled) by default; a sampling API is deferred
