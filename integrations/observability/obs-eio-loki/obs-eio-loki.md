# obs-eio-loki

Loki HTTP push backend for `obs-eio`. Converts span events into structured logfmt log
lines and pushes them to Loki's push API when each span closes. `trace_id` and `span_id`
are logfmt fields inside the log line body (searchable via `| logfmt` in LogQL), not
Loki 3's structured metadata — see [Structured Metadata](#structured-metadata) below for why.

## Package Structure

```
integrations/observability/obs-eio-loki/
  lib/
    obs_loki.ml/.mli
    obs_loki_tls.ml    ← HTTPS support; a private copy shared conceptually
                          (not in code) with obs-eio-prometheus's own copy
    dune
  test/
    test_loki.ml       ← mock-server tests (no infrastructure) + live Loki tests
    test_obs_tls.ml
    dune
```

## Public API

```ocaml
val create
  :  net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> url:string
     (** Base URL, e.g. "http://localhost:3100". Push path appended automatically. *)
  -> ?label_names:Obs_loki.stream_label list
     (** Context field names to promote to Loki stream labels (low-cardinality only).
         Missing context fields are logged to stderr and omitted. [service] is
         always included. Default: [[]]. *)
  -> unit
  -> Obs.backend
```

## Log Line Format

Each `Obs.log` call within a span becomes one Loki log line in **logfmt** format:

```
level=info msg="processing payment" span=payment.process key=val
```

Spans that close without any `Obs.log` calls emit a single completion line:

```
level=info span=payment.process status=ok
```

## Structured Metadata

Each pushed value is the plain 2-element `[timestamp_ns, log_line]` form, not Loki 3's
3-element structured-metadata tuple:

```json
["1749042259000000000", "level=info msg=hello span=op trace_id=abc... span_id=def..."]
```

`trace_id` and `span_id` are logfmt fields in the log line body instead. This is a
deliberate compatibility choice, not a gap: 3-element structured metadata is incompatible
with Loki 2.x (e.g. the loki-stack Helm chart), and putting the trace fields in the line
keeps them searchable — filterable, though not indexed or clickable the way Loki 3
structured metadata is — on both Loki 2.x and 3.x:

- **Filterable** — `{service="foo"} | logfmt | trace_id="abc..."` works in LogQL
- **Not indexed** — unlike structured metadata, these are plain line text to Loki
- **Not a dedicated Grafana Explore field** — they show up as parsed logfmt fields, not
  the structured-metadata column

Revisit this if the deployment target becomes Loki 3-only, or behind an explicit
compatibility flag.

## Stream Labels

Stream labels are always `{"service": "<service>"}` plus any selected context fields.
Keep labels low-cardinality — `env`, `region`, `tier` are good candidates; `payment_id`,
`request_id` are not.

```ocaml
let loki = Obs_loki.create ~net:env#net ~clock:env#clock
             ~url:"http://localhost:3100"
             ~label_names:[Obs_loki.stream_label "env";
                           Obs_loki.stream_label "region"] () in
let ot = Obs.create ~service:"payments-worker"
           ~mono_clock:env#mono_clock ~backend:loki in
let ot = Obs.with_context ot [("env", "prod"); ("region", "eu-west-1")] in
```

Resulting stream: `{service="payments-worker", env="prod", region="eu-west-1"}`

## Error Handling

If Loki is unreachable or returns a non-2xx status, the error is printed to stderr and
`emit_span` returns normally. The backend never raises — a Loki outage does not affect
the application.

## Timestamps

Log line timestamps are wall-clock nanoseconds from `Unix.gettimeofday()` taken at span
close time. `span_event.start_ns` / `end_ns` are monotonic and not used for timestamps
(Loki requires wall-clock Unix nanoseconds).

## Local Development

```bash
# Start Loki
bash platform/local/scripts/ensure-loki.sh

# Start Grafana (pre-wired with Loki datasource)
bash platform/local/scripts/ensure-grafana.sh

# Run tests including live Loki round-trips
cd observability && LOKI_URL=http://localhost:3100 dune test
```

Browse logs at `http://localhost:3000/explore`. Recommended queries:

```logql
{service="payments-worker"} | logfmt
{service=~"loki-.*"} | logfmt | level="error"
{service="payments-worker"} | logfmt | trace_id="<id>"
```

## HTTPS

`https://` URLs are supported: the client authenticates against the system CA bundle
(searched at the standard per-distro paths) and refuses to connect without one, rather
than silently skipping certificate verification. See `Obs_loki_tls.error_to_string` for
the failure modes.

## Buffering and Backpressure

None. `emit_span` pushes synchronously — one HTTP POST per span close, bounded by a 5s
timeout — and there is no queue or batching. This is the 0.1 behavior, not a temporary
gap; add async batching only if synchronous push latency proves unacceptable for a
target user, since a switch-owned queue and flush fiber is real lifecycle complexity.

## Out of Scope (v1)

- Batching / async push — `emit_span` is synchronous; each span close does one HTTP POST
- `emit_metric` — metrics go to `obs-eio-prometheus`, not Loki
- Loki tenant headers (`X-Scope-OrgID`) — single-tenant only
