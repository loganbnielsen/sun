# obs-eio-loki

Loki HTTP push backend for `obs-eio`. Converts span events into structured logfmt log
lines and pushes them to Loki's push API when each span closes. `trace_id` and `span_id`
are sent as Loki 3.x structured metadata — indexed and filterable in Grafana Explore,
separate from the log line text.

## Package Structure

```
integrations/observability/obs-eio-loki/
  lib/
    obs_loki.ml/.mli
    dune
  test/
    test_loki.ml       ← mock-server tests (no infrastructure) + live Loki tests
    dune
```

## Public API

```ocaml
val create
  :  net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> url:string
     (** Base URL, e.g. "http://localhost:3100". Push path appended automatically. *)
  -> ?label_names:string list
     (** Context field names to promote to Loki stream labels (low-cardinality only).
         [service] is always included. Default: [[]]. *)
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

`trace_id` and `span_id` are sent as Loki 3.x structured metadata (third element of the
value tuple), not embedded in the log line text:

```json
["1749042259000000000", "level=info msg=hello span=op", {"trace_id": "abc...", "span_id": "def..."}]
```

This makes them:
- **Indexed** — Loki stores them as searchable fields
- **Filterable** — `{service="foo"} | trace_id="abc..."` works in LogQL
- **Clickable** — appear as dedicated fields in Grafana Explore's log detail view

## Stream Labels

Stream labels are always `{"service": "<service>"}` plus any context fields whose names
appear in `label_names`. Keep labels low-cardinality — `env`, `region`, `tier` are good
candidates; `payment_id`, `request_id` are not.

```ocaml
let loki = Obs_loki.create ~net:env#net ~clock:env#clock
             ~url:"http://localhost:3100"
             ~label_names:["env"; "region"] () in
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
{service="payments-worker"} | trace_id="<id>"
```

## Out of Scope (v1)

- Batching / async push — `emit_span` is synchronous; each span close does one HTTP POST
- HTTPS / TLS — plain HTTP only; terminate TLS at a proxy
- `emit_metric` — metrics go to `obs-eio-prometheus`, not Loki
- Loki tenant headers (`X-Scope-OrgID`) — single-tenant only
