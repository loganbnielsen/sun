# Work Summary — root layout cleanup in progress

## Latest: root layout cleanup

Reduced root-level clutter without changing core package boundaries.

**Moved:**
- Planning docs to `docs/planning/`.
- Product architecture and tutorial docs to `docs/architecture/` and `docs/guides/`.
- Audit checklists to `docs/audits/`.
- Deployment and hosted reference docs to `docs/deployment/` and `docs/hosted/`.
- Example workspaces/demos to `examples/`.

**Kept at root intentionally:**
- `README.md`, `dune-project`, `dune-workspace`.
- Core package groups: `cli/`, `integrations/kafka/`, `integrations/observability/`, `framework/`, `integrations/storage/`.
- Operational/project directories: `platform/local/`, `platform/infra/`, `project/tickets/`, `tools/perf/`, `project/audits/`.

---

# Previous — hosted release inspection

## Latest: FEAT-015 — hosted release inspection and diagnostics

Added a read-only release inspection model for hosted and customer-cloud release
visibility.

**Changed:**
- `Sun_cli_release_inspection` module with release summaries, affected services,
  rollout/health status fields, rendered manifest facts, diagnostic events, and
  diagnostics JSON serialization.
- `Sun_cli_hosted_executor.release` now embeds an inspection summary in the mock
  hosted release response.
- `docs/hosted/hosted-release-inspection.md` documents the default hosted release view,
  advanced diagnostics, customer-cloud manifest inspection, and non-goals.
- Tests cover release summary JSON, diagnostic manifest facts, secret-value
  absence, and hosted response inspection payloads.

**Verification so far:**
- `eval $(opam env) && dune test cli/sun/test`

---

# Previous — audit remediation + testing harness complete

## Latest: 2026-06-08 audit — all actionable findings resolved

All 5 numbered audit findings (AUDIT-010 through AUDIT-014) resolved. Four additional
unverified items investigated and fixed. Pre-commit hooks, performance baseline
tracking, and e2e assertions committed.

### AUDIT-010 — `sun_worker_decode_errors_total` Prometheus counter
`consume` and `consume_partitioned` now accept `?ot : Obs.t option`. When provided,
a `sun_worker_decode_errors_total` counter is registered and incremented on every
`on_decode_error` call (bad wire format, JSON parse error, schema decode). `sun-worker`
forwards its `?ot` through to `consume_partitioned` automatically.

### AUDIT-011 — Worker template acks after business logic (committed earlier)
Both `ws_worker_ml` and `worker_lib_ml` scaffold templates now call `ack()` inside
the `Ok` branch of the DB insert, after all side effects succeed.

### AUDIT-012 — Retry path checks publish result before acking (committed earlier)
`publish_raw` now uses `Eio.Promise.await` on the producer result. On `Error`, it
logs to stderr and returns `Error e` without calling `ack()`, so the message is
not lost when the broker is unavailable.

### AUDIT-013 — HTTPS schema registry detected clearly (committed earlier)
`parse_base_url` now fails with a clear `failwith` message when an `https://` URL is
passed, avoiding a confusing DNS error. Test added for the rejection path.

### AUDIT-014 — `CAMLparam`/`CAMLreturn` in pause/resume partition stubs (committed earlier)
`ocaml_rd_kafka_pause_partition` and `ocaml_rd_kafka_resume_partition` now have full
`CAMLparam3` / `CAMLreturn(Val_unit)` discipline, consistent with all other stubs.

### Remaining unverified audit items investigated

**conf_of_config naked exceptions** — `kafka_consumer` and `kafka_producer` both had
`conf_of_config` calling `failwith` on `rd_kafka_conf_set` failure. Breaks the
`(t, Kafka_error.t) result` contract of `create`. Fixed: `conf_of_config` now returns
`(Kafka_raw.kafka_conf, string) result`; `create` logs the message to stderr and
returns `Error Kafka_error.Application`. Type annotation added to prevent OCaml
unifying the string error with `Kafka_error.t` (both `Result.Error` and
`handler_result.Error` constructors accept `Kafka_error.t` without annotation).

**Distributed tracing HTTP injection** — `Request.t` lacked a typed `trace_ctx` field.
Handlers had to manually extract `traceparent` from raw headers. Fixed: `Request.t`
now includes `trace_ctx : Obs_trace.t option`, populated by `service.ml` from the
incoming `Http.Header.t` via `Obs_trace.extract_from_headers`. Matches the UX of
worker handlers which already received `~trace_ctx`.

**Prometheus label cardinality** — Verified: route label is `route.Route.pattern`
(e.g. `/users/:id`), not the actual request path. Test added: two requests to
`/users/42` and `/users/999` confirm only `route="/users/:id"` appears in the
metrics output, never the concrete values.

**Migration tracking workspace isolation** — `sun migrate` already had `--table`.
Scaffold README and printed instructions updated to use `--table {{name}}_migrations`
so each workspace's version tracking is isolated from other workspaces sharing the
same postgres database.

### Testing harness (committed earlier in session)

- **Pre-commit hook** (`tools/perf/hooks/pre-commit`): blocks commits on build failure, unit
  test failure, or performance regression. Kafka tests gated on broker being up; e2e
  gated on broker + Loki + Postgres all running. Skip with `SUN_SKIP_HOOKS=1`.
- **Post-commit hook** (`tools/perf/hooks/post-commit`): shows perf table after commit.
- **Performance baselines** (`tools/perf/perf_baseline.json`): unit 0.2s, kafka 1.0s, e2e
  10.2s. Regression threshold 1.2×.
- **E2e assertions** (`examples/local-demo/bin/demo.ml`): HTTP 202 for all orders, Prometheus
  `sun_svc_requests_total > 0`, `sun_worker_messages_total > 0`, Loki query-back for
  service=order-svc, PostgreSQL row count ≥ orders sent.

### Remaining open audit items (not quick-fix)

- **Hermetic container portability**: Dockerfile copies host-built binary. Multi-stage
  OCaml builds via `ocaml/opam` image work but first-build time is 15–30 min and
  requires opam lockfile generation. Deferred to Phase 7 / infra hardening.
- **Zero-Knowledge Onboarding**: requires running `sun new workspace` end-to-end with
  k3d cluster provisioning; not verified in this session.
- **Hermetic test harnesses**: bash scripts with manual broker setup. Fixing requires
  Docker-in-CI or testcontainers support; deferred.
- **Atomic CLI transactions**: `sun up` applies workloads but doesn't roll back
  namespace on partial failure. Design-level issue; deferred.

---

## Previous: `Retry_topics` strategy + per-partition fiber retry + three code-review fixes

### `Kafka_service.retry_strategy` (new)

Two-mode union type added to `kafka_service.ml/mli`:

```ocaml
type retry_strategy =
  | In_memory    of Kafka_consumer.retry_policy  (* existing behavior, default *)
  | Retry_topics of { max_attempts : int }       (* new: Kafka-native retry *)
```

`consume_partitioned` now takes `?retry_strategy` (replacing `?retry`). Both
`Kafka_service` and `Worker.Make(W).run` surface this parameter.

**`Retry_topics` mechanics:**
- On handler `Error _`: raw bytes are published to `<topic>-retry` with
  `X-Sun-Attempt` and `X-Sun-Retry-At` headers; original offset committed
  immediately; main partition keeps flowing (returns `Continue`).
- Background retry consumer (`group_id ^ "-sun-retry"`) subscribes to
  `<topic>-retry`. Per message: reads `X-Sun-Retry-At`, calls
  `pause_partition`, sleeps until ready, calls `resume_partition`, then
  re-runs the handler.
- On re-failure: increments attempt and re-publishes to `<topic>-retry`
  (capped at 10 min backoff) or `<topic>-dlq` after `max_attempts`.
- Both topics auto-provisioned via AdminClient on startup.
- Retry consumer fiber runs in the caller's `sw`; Eio cancellation propagates
  naturally on shutdown — no explicit stop signal needed.

**Changed files (retry_strategy):**
- `integrations/kafka/kafka-eio-service/lib/kafka_service.ml[i]` — `retry_strategy` type, `default_retry_strategy`, modified `consume_partitioned`
- `framework/sun-worker/lib/worker.ml[i]` — `retry_strategy` type alias, `?retry_strategy` param in `Make.run`

**Three code-review fixes (stream capacity, stop race, `[@@noalloc]`):**
- `integrations/kafka/kafka-eio-consumer/lib/kafka_consumer.ml` — `Eio.Stream.create 64` → `max_int`; explicit `else ()` on interrupted retry
- `integrations/kafka/kafka-eio-core/lib/kafka_raw.ml` — `[@@noalloc]` on `pause_partition`/`resume_partition`
- `integrations/kafka/kafka-eio-core/lib/kafka_stubs.c` — dropped `CAMLprim`/`CAMLparam3`/`CAMLreturn` from pause/resume (required by `[@@noalloc]`)

**Test result:** 68 unit tests, all passing.

## Previous: Per-partition fiber consumer with retry + pause/resume

### `kafka_consumer.consume_partitioned` (new)

Routes messages to a per-partition `Eio.Stream.t`. One `Eio.Fiber.fork ~sw` per new partition. Each fiber runs the handler independently with exponential backoff retry. During retry sleep the partition is **paused at the librdkafka level** (`rd_kafka_pause_partitions`) so no messages accumulate in the partition stream — no memory buffer blowup and no head-of-line blocking in the routing loop.

**Key design points:**
- Routing loop uses `Eio.Fiber.first` to race `Stream.take t.stream` against a stop promise, so a `Stop` from any partition during a quiescent period doesn't block the routing loop forever.
- Sleeping partition fibers also use `Eio.Fiber.first` to race `Eio.Time.sleep clock delay` against the stop promise — so a `Stop` signal wakes them immediately; `resume_partition` is called before the fiber exits.
- Inner `Eio.Switch.run` inside `consume_partitioned` ensures all partition fibers join before the function returns, making it safe for the caller to immediately destroy the consumer handle.
- `worker.ml` no longer contains any retry logic. The handler returns `Kafka_consumer.Error Kafka_error.Application` for `W.handle` errors; `consume_partitioned` handles retry. The `_consume_loop` test-injection path bypasses partitioning (no sleep, no retry — tests remain fast).

**New C stubs:** `ocaml_rd_kafka_pause_partition`, `ocaml_rd_kafka_resume_partition` (local ops, no lock release needed).

**Changed files:**
- `integrations/kafka/kafka-eio-core/lib/kafka_stubs.c` — pause/resume stubs
- `integrations/kafka/kafka-eio-core/lib/kafka_raw.ml[i]` — `pause_partition`, `resume_partition` externals
- `integrations/kafka/kafka-eio-consumer/lib/kafka_consumer.ml[i]` — `retry_policy` type, `default_retry`, `consume_partitioned`
- `integrations/kafka/kafka-eio-service/lib/kafka_service.ml[i]` — `consume_partitioned` wrapper
- `framework/sun-worker/lib/worker.ml[i]` — simplified handler (no inline retry), calls `consume_partitioned`
- `framework/sun-worker/test/test_worker.ml` — updated `one_message`/`two_messages` for new `Error` semantic

**Test result:** 14/14 suites pass (121 tests). No hangs.

---

## What was done

### 1. `obs-eio` core library (complete, 18/18 tests)

New workspace at `integrations/observability/` with package `obs-eio`.

**Modules:**
- `Obs_trace` — W3C `traceparent` encode/decode, `generate`, `child_span`, `inject_to_headers`, `extract_from_headers`
- `Obs_metrics` — type aliases for `counter_fn`, `gauge_fn`, `histogram_fn` emitter closures
- `Obs` — main handle (`t`), `backend` record, `with_span`, `log`, `register_counter/gauge/histogram`, `with_context`, `noop`, `stdout`, `compose`

**Key design:** `Obs.t` is immutable — `with_context` returns a new handle; safe to fork per-fiber. `span_event` carries `context : (string * string) list` so backends can use ambient fields as stream labels.

### 2. `obs-eio-loki` backend (complete, 8/8 tests)

New package at `integrations/observability/obs-eio-loki/`.

**API:**
```ocaml
val create
  :  net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> url:string
  -> ?label_names:string list
  -> unit
  -> Obs.backend
```

**What it does:**
- One logfmt log line per `Obs.log` call: `level=info msg=... span=... key=val`
- `trace_id` and `span_id` in Loki 3.x **structured metadata** (third element of the value tuple) — indexed as filterable fields in Grafana, not buried in the log line text
- Stream labels: `service` always + whitelisted `label_names` from `Obs.t` context (low-cardinality only)
- Spans with no `Obs.log` calls emit a single `level=info span=... status=ok` completion line
- Unreachable Loki logs to stderr and returns normally — never raises

**Tests:**
- 6 mock-server tests verify payload structure without external infrastructure
- 2 live tests against real Loki: `log line ingested and queryable`, `trace_id indexed as structured metadata`
  (gated on `LOKI_URL` env var; run via full e2e matrix)

**Infrastructure added:**
- `platform/local/scripts/ensure-loki.sh` — starts `grafana/loki:3.0.0` via Docker
- `platform/local/scripts/ensure-grafana.sh` — starts Grafana, creates `sun-obs` Docker network, provisions Loki datasource
- Grafana UI at `http://localhost:3000/explore`; recommended query: `{service=~"..."} | logfmt`

### 3. Kafka Layer Hardening (complete, 26/26 tests)

All Kafka e2e tests green. See previous summary for details.

### 4. `obs-eio-prometheus` backend (complete, 10/10 tests)

New package at `integrations/observability/obs-eio-prometheus/`.

**API:**
```ocaml
val create : unit -> Obs.backend * (unit -> string)
(* backend accumulates counter/gauge/histogram deltas;
   renderer produces Prometheus /metrics text on demand *)
```

**What it does:**
- Counter: accumulates `+= delta` per `(name, sorted_labels)` key, never resets
- Gauge: last-write-wins replacement per `(name, sorted_labels)` key
- Histogram: default buckets `[0.005; 0.01; 0.025; 0.05; 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0]`;
  Prometheus cumulative semantics (increment all buckets where `le >= observation`)
- `emit_span` is a no-op — spans go to Loki
- `Mutex` (not `Eio.Mutex`) protects the registry — safe across Eio domains, no switch needed
- Renderer snapshots under the lock, then formats (does not hold lock while building the string)
- `# HELP` lines rendered — required adding `help: string` to `Obs.metric_event` (additive, all existing tests still pass)

**Tests:**
- Counter accumulation across label sets, unlabeled counter
- Gauge last-write-wins, independent label sets
- Histogram correct bucket sorting, sum, count, labeled histogram lines
- Renderer: empty on zero events, `# HELP`/`# TYPE` lines, label value escaping
- Concurrent emit via `Eio.Fiber.all` — no lost updates under 100 fibers × 10 emits

**`push` implemented** — brought forward from Phase 2 for live verification.
Pushes Prometheus text body via HTTP PUT to `/metrics/job/<job>` on Pushgateway.
Same minimal TCP pattern as obs-eio-loki. Returns `(unit, string) result`; never raises.

### 5. `sun-svc` HTTP service layer (complete, 32/32 tests)

New package at `framework/sun-svc/`.

**Modules (wrapped library):**
- `Auth` — three-level auth: `` `Public ``, `` `Api_key `` (SUN_API_KEY / SUN_API_KEY_FILE), `` `Jwt of jwt_config `` (structure + exp + scope validated; `allow_unverified_v1_unsafe` guard for v1)
- `Response` — plain record `{ status; headers; body }` with typed constructors (`ok`, `json`, `created`, `bad_request`, `unauthorized`, etc.)
- `Request` — request record with `param_exn`, `query_param`, `header` helpers
- `Route` — `get`, `post`, `put`, `patch`, `delete` constructors; `match_path` with `:name` capture; trailing-slash distinction
- `Service` — `HANDLER` module type + `Make` functor; `run` with graceful shutdown, drain timeout, built-in `/healthz` and `/metrics` endpoints

**Key design decisions:**
- `cohttp-eio 6.2.1` as HTTP engine: `Server.run` takes listening socket, `?stop` promise for graceful shutdown
- Must add `Content-Length` header explicitly — cohttp-eio 6.x's `Body.String` read-method detection does not fire in practice (falls back to chunked)
- `Fiber.fork_daemon ~sw` in tests: `Eio.Net.run_server`'s io_uring accept doesn't respond to switch cancellation on WSL2; daemon fibers allow test switch to exit without waiting
- Graceful shutdown uses `Eio.Fiber.first serve drain_guard` — if connections drain before the timeout, the server exits immediately (no artificial delay); if drain_timeout_s elapses, `drain_guard` raises `Drain_timeout`, which is caught at the switch boundary with a log line
- Signal handling via self-pipe trick: `Unix.set_nonblock w` + `Unix.single_write` in the `Sys.Signal_handle` (async-signal-safe), `Eio_unix.await_readable r` in a forked fiber that resolves the stop promise from the Eio domain
- API key comparison uses constant-time XOR loop (`constant_time_equal`) to eliminate timing side-channels
- API key file reads are mtime-cached: `Atomic` ref holds `(mtime, key)`; fast path is `Unix.stat` + `Atomic.get` (no lock); `Mutex.protect` serialises the single writer on cache miss (double-checked locking); `In_channel.with_open_text` guarantees channel cleanup
- Double-slash paths (`/users//42`) rejected with 400 before routing via a zero-allocation tail-recursive `has_double_slash` using `String.unsafe_get`

**Tests (32 total):**
- `test_routing` — 10 tests: path matching, trailing slash, params, method mapping
- `test_auth` — 11 tests: Public, API key valid/wrong/missing, JWT valid/scopes/expired/malformed/unsafe-flag
- `test_service` — 11 tests: healthz, metrics, 404/405, public route, path params, POST body echo, JWT auth, handler exception resilience

### 6. `sun-fn` function primitive (complete, 7/7 tests)

New package at `framework/sun-fn/`.

**API:**
```ocaml
module type FN = sig
  val schedule : string                        (* cron expression *)
  val run : unit -> (unit, string) result
end

module Make (F : FN) : sig
  val run
    :  env:< net : _ Eio.Net.t; clock : _ Eio.Time.clock;
             mono_clock : _ Eio.Time.Mono.t; .. >
    -> ?pushgateway_url:string
    -> ?job:string
    -> ?backend:(Obs.backend * (unit -> string))
    -> unit -> unit
end
```

**Lifecycle:** `Fiber.first` returns a typed outcome (`` `Completed result | `Signalled ``); metrics recording and push happen unconditionally OUTSIDE `Fiber.first` so they can never be cancelled mid-write.

**Signal handling:** Self-pipe (`fork_daemon ~sw`) — identical pattern to `sun-svc` but uses `fork_daemon` so the switch exits cleanly when `F.run ()` returns without any signal being received.

**Push safety:** `Obs_prometheus.push` has a 5s internal timeout; the outer `push_metrics` helper catches all exceptions and logs to stderr — push never blocks exit.

**`?backend` parameter:** Optional override for the default `Obs_prometheus.create ()` pair. Enables metric inspection in tests (without a real pushgateway) and fan-out to additional backends via `Obs.compose`.

**Build structure change:** Removed `integrations/observability/dune-project` and `framework/dune-project`; created root `dune-project`. This merges both into the root project so cross-package library deps (`obs_eio`, `obs_eio_prometheus`) resolve correctly. `integrations/kafka/dune-project` is unchanged. All builds still work from subdirectories (dune finds workspace root via `dune-workspace`).

**Tests (7 total):**
- `run_ok` — `Ok ()` → returns normally
- `run_error` — `Error msg` → raises `Failure msg`
- `run_exception` — unhandled exception propagated
- `metrics_ok_counter` — renderer contains `sun_fn_invocations_total{status="ok"}`
- `metrics_error_counter` — renderer contains `status="error"`
- `metrics_duration` — renderer contains `sun_fn_duration_seconds`
- `push_error_no_raise` — connection-refused pushgateway → swallowed, returns in <5s

---

### 7. Phase 3 — Observability auto-wiring in `sun-svc` (complete, 13/13 tests)

Added `?ot:Obs.t` parameter to `Service.Make(H).run`. When provided:
- Registers `sun_svc_requests_total{method, route, status_class}` counter and `sun_svc_request_duration_seconds{method, route}` histogram at startup (once, not per request)
- Per request: captures matched route pattern via `?route_observer` hook into `dispatch` (zero extra route-lookup cost), then emits counter + histogram after response is built
- Route label uses the declared pattern (`/users/:id`), not the actual path — no cardinality explosion

**Usage:**
```ocaml
let backend, render = Obs_prometheus.create () in
let ot = Obs.create ~service:"payments-svc" ~mono_clock:env#mono_clock ~backend in
Service.Make(H).run ~env ~ot ~metrics_renderer:render ()
```

`-fn` already had `sun_fn_invocations_total` + `sun_fn_duration_seconds` from Phase 2. No additional changes needed.

**What's deferred:** `-worker` (no primitive yet), Grafana dashboards, k8s manifests (Phase 6), `Sun.Log`/`Sun.Metrics` wrappers (Phase 5).

### 8. `sun-worker` worker primitive (complete, 7/7 tests)

New package at `framework/sun-worker/`.

**API:**
```ocaml
module type WORKER = sig
  module Message : Kafka_service.MESSAGE
  val group_id : string
  val handle : Message.t -> ack:(unit -> unit) -> (unit, string) result
end

module Make (W : WORKER) : sig
  val run
    :  env:< net : _ Eio.Net.t; clock : _ Eio.Time.clock;
             mono_clock : _ Eio.Time.Mono.t; .. >
    -> config:Kafka_service.config
    -> ?ot:Obs.t
    -> unit -> unit
end
```

**Lifecycle:** `create` → `register` → `consume` inside a switch. Signal handler sets an `Atomic.t` stop flag; handler checks it per message for graceful drain. Handler error (`Error msg`) captured via ref → raises `Failure` after consume exits cleanly via `Stop`.

**Signal handling:** Same self-pipe pattern as `-svc` and `-fn`. Uses `Atomic.t` rather than a promise because the stop is checked at message boundaries (not mid-message cancellation).

**Metrics (when `?ot` provided):**
- `sun_worker_messages_total{status}` — counter (`ok` or `error`)
- `sun_worker_message_duration_seconds` — histogram (per-message latency)

**Test injection:** `?_consume_loop` parameter bypasses the real Kafka stack and drives the wrapped handler with synthetic messages — same pattern as `?backend` in `sun-fn`.

**Build change:** Deleted `integrations/kafka/dune-project` to merge the kafka sub-project into the root project. `sun-worker` can now depend on both `kafka_eio_service` and `obs_eio` without cross-workspace issues. All 111 tests still pass.

**Tests (7 total):**
- `handle_ok` — Ok () handler → returns normally
- `handle_error_raises` — Error handler → raises Failure
- `no_ot_no_crash` — runs without ?ot, no crash
- `two_messages_both_processed` — two messages, both processed
- `metrics_ok_counter` — renderer contains `sun_worker_messages_total{status="ok"}`
- `metrics_error_counter` — renderer contains `status="error"`
- `metrics_duration` — renderer contains `sun_worker_message_duration_seconds`

---

### 9. E2E demo + Friction Log (complete)

New `examples/local-demo/` at repo root. Full stack in one binary: HTTP → svc → Kafka → worker.

**Shows:**
- `correlation_id` from HTTP `X-Correlation-Id` → Kafka event payload → worker log spans
- Auto-wired metrics: `sun_svc_requests_total`, `sun_svc_request_duration_seconds`, `sun_worker_messages_total`, `sun_worker_message_duration_seconds`  
- Prometheus text output; optional Loki (LOKI_URL) and Pushgateway (PUSHGATEWAY_URL)

**Run:** `KAFKA_BROKERS=localhost:9092 dune exec examples/local-demo/bin/demo.exe`

**Also:** `http/` folder renamed to `framework/`. See `examples/local-demo/FRICTION_LOG.md` for 7 friction items to reduce developer barrier to entry.

---

### 10. Friction log — Batch 1 (complete)

Three quick-win improvements from the demo friction log:

**`Worker.Make.run ?on_ready`** (`framework/sun-worker/lib/worker.ml/.mli`)
- Added `?on_ready:(unit -> unit)` parameter; threads directly to `Kafka_service.consume`.
- Demo updated to use real path — `~_consume_loop` friction hack removed.

**`Obs.log_t`** (`integrations/observability/obs-eio/lib/obs.ml/.mli`)
- `val log_t : t -> level -> ?fields:(string * string) list -> string -> unit`
- Addresses friction items #4 and #7. Logs without an explicit span; creates an anonymous `"log"` span internally.

**`Kafka_service.config_of_env`** (`integrations/kafka/kafka-eio-service/lib/kafka_service.ml/.mli`)
- `val config_of_env : unit -> config`
- Reads `KAFKA_BROKERS`, `SCHEMA_REGISTRY_URL`, `REDPANDA_ADMIN_URL` with sensible localhost defaults (`linger_ms=50`, `partitions=1`).
- Demo updated to use `{ (Kafka_service.config_of_env ()) with linger_ms = 5 }`.

All 111 unit tests pass. Full e2e demo runs clean (no hangs).

### 10b. Critical hang fix — `Eio.Cancel.protect` + stream-drain deadlock (complete)

Two shutdown bugs fixed, found while running e2e tests with long-running topics:

**Bug 1 — `Eio.Cancel.protect` missing** (`kafka_consumer.ml`, `kafka_producer.ml`):
Without `Eio.Cancel.protect` in `close`, an outer switch ending while `close` is waiting at `Eio.Promise.await t.poll_exited` (a yield point) raises `Eio.Cancel.Cancelled`, skipping `consumer_close`/`flush`/`destroy`. Librdkafka background threads leak, hold the consumer group open, and block any new consumer joining the same group in a rebalance that never completes. Fixed by wrapping the entire shutdown sequence in `Eio.Cancel.protect`.

**Bug 2 — stream-full deadlock** (`kafka_consumer.ml`):
When `close` is called explicitly (not from `on_release`) and the 256-message stream is full, the poll fiber is blocked in `Eio.Stream.add`. `close` waits for `poll_exited`, but the poll fiber can never see `t.closed = true` to exit. Fixed by draining the stream inside `close` before awaiting `poll_exited`:
```ocaml
let rec drain_until_exited () =
  while not (Eio.Stream.is_empty t.stream) do
    ignore (Eio.Stream.take_nonblocking t.stream)
  done;
  if Eio.Promise.peek t.poll_exited = None then begin
    Eio.Fiber.yield ();
    drain_until_exited ()
  end
in
drain_until_exited ();
```

**Results:** All 26 Kafka tests pass in <1.5s total (was hanging indefinitely). Demo runs to completion with clean process exit — no stale librdkafka threads.

### 11. Friction log — Batch 3: traceparent over Kafka headers (complete)

W3C `traceparent` automatically propagated from HTTP span → Kafka message header → worker span, creating a full distributed trace across the svc→kafka→worker boundary.

**Changes (9 layers):**
- `kafka_stubs.c` — `consumer_poll` extended to 7-tuple (adds `headers:(string*string) list`); new `produce_v` stub using `rd_kafka_producev` for header-bearing produces
- `kafka_raw.ml/.mli` — updated externals for 7-tuple poll and `produce_v` with bytecode trampoline
- `kafka_consumer.ml/.mli` — `message` type gains `headers` field; `tuple_to_message` updated
- `kafka_producer.ml/.mli` — `produce`/`produce_await` gain `?headers:(string*string) list`; routes through `produce_v` when non-empty
- `kafka_service.ml/.mli` — `publish` gains `?trace_ctx:Obs_trace.t`; `consume`'s handler type gains `~trace_ctx:Obs_trace.t option`
- `framework/sun-worker/lib/worker.ml/.mli` — `WORKER.handle` gains `~trace_ctx:Obs_trace.t option`
- All tests updated for the new handler signatures
- `examples/local-demo/bin/demo.ml` — extracts `trace_ctx` from HTTP span via `Obs.current_trace_ctx`, passes to `publish`; worker uses `?parent:trace_ctx` to link the fulfillment span

**Trace continuity:** HTTP span → `traceparent` header in Kafka message → extracted in `kafka_service.consume` → passed to `WORKER.handle` as `~trace_ctx` → `?parent:trace_ctx` in `Obs.with_span` → linked child span in Loki/Grafana.

### 12. Demo friction log — all items closed (complete)

All 7 friction items from `examples/local-demo/FRICTION_LOG.md` are resolved:

| # | Item | Resolution |
|---|------|------------|
| 1 | `Worker.Make.run ~on_ready` | `?on_ready:(unit -> unit)` threaded to `Kafka_service.consume` |
| 2 | Worker clean stop mechanism | `?stop:bool Atomic.t` + `?max_messages:int`; 2 dedicated test cases |
| 3 | `(wrapped)` inconsistency | All three primitives now `(wrapped false)` |
| 4 | Logging boilerplate | `Obs.log_t : t -> level -> ?fields -> string -> unit` |
| 5 | Correlation ID manual end-to-end | W3C `traceparent` over Kafka headers (Batch 3) |
| 6 | Two Kafka credentials | `Kafka_service.config_of_env ()` |
| 7 | `Obs.log` requires span | Same fix as #4 |

### 13. Error handling and test-speed hardening (complete)

Two targeted cleanups:

**Narrowed broad exception catches** (`integrations/kafka/kafka-eio-service/lib/kafka_service.ml`):
- `with _ ->` catches in schema registry JSON parsing narrowed to `Yojson.Json_error _`
- Previously swallowed `Out_of_memory`, `Stack_overflow`, and other fatal exceptions silently

**Loki live test sleep reduced** (`integrations/observability/obs-eio-loki/test/test_loki.ml`):
- `Eio.Time.sleep 2.0` → `0.5` in both live round-trip tests
- Justified: `emit_span` pushes synchronously (HTTP POST completes before `with_span` returns); Loki query latency after ingestion is <100ms in practice
- Full e2e suite: **1.64s** (was 4.15s), all 84 tests green

### 14. Phase 4 — Storage (PostgreSQL) (complete, 8/8 tests)

New package at `integrations/storage/sun-storage/`.

**Modules:**
- `Storage_error` — typed error ADT: `Connection_failed`, `Query_error`, `Not_found`, `Constraint_violation`, `Migration_error`
- `Db` — connection pool (`create_pool`), `exec`, `find`, `collect`, `transaction`; polymorphic record field trick hides caqti's type variable; `App_error` exception bridges `Pool.use` callback type boundary
- `Migration` — migration runner: `apply pool ~dir` applies pending `NNNN_description.sql` files in order; idempotent; tracks applied versions in `sun_schema_migrations`; `status pool ~dir` returns per-migration status
- `Table.Make(SCHEMA)` — functor producing `find`, `insert`, `delete`, `list` from a schema description; SQL generated at functor instantiation time

**Key design decisions:**
- No storage abstraction layer — PostgreSQL is the answer, not a pluggable option
- `caqti` + `caqti-driver-postgresql` + `caqti-eio.unix` (C-binding driver requires `.unix` sub-library, not plain `caqti-eio`)
- `Caqti_eio.stdenv` coerced from full env with `:>` — requires `< net; clock; mono_clock >`
- `Pool.use` callback must return caqti error type; `App_error` exception trick enables `Storage_error.t` across that boundary without losing type safety
- `transaction` builds a `tx_pool = { use_conn = fun g -> g conn }` — routes all queries to the same connection
- Migration files: `NNNN_description.sql`; `sun_schema_migrations (version INT PK, name TEXT, applied_at TIMESTAMPTZ)`
- All integration tests gated on `POSTGRES_URL` env var; 2 pure unit tests run without database

**Tests (8 total):**
- Unit: `error_to_string`, `migration_parse_filename` (no database)
- Integration: `pool_create`, `exec_find_collect`, `transaction_commit`, `transaction_rollback`, `migration_apply` (idempotent), `table_make` (full CRUD via `Caqti_type.custom`)

**Infrastructure:** `platform/local/scripts/ensure-postgres.sh` — starts `postgres:16-alpine`, waits for `pg_isready`, prints `export POSTGRES_URL=...`

**Build:** `dune build integrations/storage/` clean first try. 8/8 tests pass in 217ms.

### 15. Venus reference workspace (complete)

New `examples/venus/` workspace that uses Sun rather than defines it — a realistic two-team example.

**Architecture:**
```
payments / charge-svc  →  Kafka (venus-payments-charges)  →  comms / notify-worker  →  PostgreSQL
```

**Structure:**
```
examples/venus/
  events/payments/charged.ml         ← Charged event contract (payments team owns, comms team imports)
  app/comms/notify_worker/lib/
    notification.ml                  ← Table.Make(Schema) for notifications table
    notify_worker.ml                 ← Worker.WORKER impl via Make(Config) functor
  db/migrations/0001_notifications.sql
  bin/run.ml                         ← orchestration runner (replaces examples/local-demo/)
```

**Key patterns demonstrated:**
- Two autonomous teams collaborating through a typed Kafka event contract
- `Notify_worker.Make(Config)` functor: injects `pool` and `ot` without module-level mutable state
- `~table:"venus_schema_migrations"` in `Migration.apply` — per-workspace migration table avoids cross-contamination when multiple workspaces share a dev database
- `Notification.Schema.t` + `include Table.Make(Schema)` pattern for storage modules
- `Obs.with_context` wires `team` label into Loki stream labels per service

**Bug fixed during implementation:**
- `Migration.apply`/`status` now accept `?table:string` (default `"sun_schema_migrations"`)  
- Storage test updated to use a random per-run table name for isolation
- Root cause: demo's migration ran first and recorded version 1 in `sun_schema_migrations`, causing venus's `0001_notifications.sql` to be silently skipped

**Run:** `KAFKA_BROKERS=... POSTGRES_URL=... LOKI_URL=... dune exec examples/venus/bin/run.exe`

## In Progress

### 16. Phase 5 — CLI skeleton and scaffold commands (in progress)

**Package:** `cli/sun/`  
**Binary:** `_build/default/cli/sun/bin/main.exe` (install as `sun`)

**`Sun_cli` library (`cli/sun/lib/`):**
- `Sun_cli_scaffold` — `subst`, `write_file`, `normalize`, `capitalize_name`; template substitution using `{{key}}` placeholders; directory creation via `Sys.command "mkdir -p"`
- `Sun_cli_workspace` — workspace scanner: walks `dune` files under a directory and returns `infra_requirements { kafka; postgres; loki; prometheus }` for use by `sun dev up`

**Full CLI surface wired via `cmdliner` 2.x:**

| Command | Status |
|---------|--------|
| `sun new workspace <name>` | ✓ fully implemented |
| `sun new svc <domain>/<name>` | ✓ fully implemented |
| `sun new worker <domain>/<name>` | ✓ fully implemented |
| `sun new fn <domain>/<name>` | ✓ fully implemented |
| `sun new event <team>/<name>` | ✓ fully implemented |
| `sun dev up/down/status` | stub — Phase 5 step 2 |
| `sun up [path] [--dry-run] [--tag]` | stub — Phase 5 step 3 |
| `sun status [domain]` | stub — Phase 5 step 4 |
| `sun migrate [status\|rollback]` | stub — Phase 5 step 7 |

**Scaffold contract (verified with `dune build`):**
- `sun new workspace acme` → 15 files; `dune build acme/` passes first try
- Generated workspace contains: typed `Charged` event (satisfies `MESSAGE`), `charge_svc` handler (satisfies `Service.HANDLER`), `notify_worker` (satisfies `Worker.WORKER`), migration SQL, Dockerfiles, `sun.toml` stubs
- `sun new svc/worker/fn` → minimal but complete primitive that compiles immediately; worker bin uses `let module W = Worker.Make(Notify_worker)` pattern (required by OCaml parser for functor access in expression position)
- `sun new event` → typed `MESSAGE` module + dune file; appends note if `events/<team>/dune` already exists

**Phase 5 step 2 complete — `sun dev up/down/status`:**
- `cmd_dev.ml` fully implemented: k3d cluster lifecycle, Helm chart installs (Redpanda, PostgreSQL, Loki, prometheus-community/prometheus), port-forward manager (PID files in `.sun/`), endpoint summary table
- `type set_val = Val of string | Str of string` distinguishes `--set` (YAML-parsed) from `--set-string` (always string) — prevents int64 coercion from rejecting Redpanda `cpu.cores` and `statefulset.replicas`
- Helm chart/service name corrections: `grafana/loki-stack` (not separate loki + grafana), `prometheus-community/prometheus` (lightweight; includes pushgateway), service names `loki` and `loki-grafana` (not `loki-stack*`)
- Schema registry (8081) and Pushgateway (9091) port-forwards wired
- Workspace scanner wired via `Sun_cli_workspace.scan ~dir:"."` — detects which infra charts to install
- Graceful error messages when k3d/helm/kubectl are not in PATH (prints install URL and exits 1)

**Phase 5 step 7 complete — `sun migrate`:**
- `cmd_migrate.ml` fully implemented: thin Eio + caqti wrapper over `Sun.Storage.Migration`
- `sun migrate` / `sun migrate apply` — applies pending migrations from `--dir` (default `db/migrations/`)
- `sun migrate status` — prints per-file applied/pending table with timestamps
- `sun migrate rollback` — prints helpful stub (no-op rollback; manual down-migration suggested)
- Reads `POSTGRES_URL` from env; clear error if missing
- `--table` flag for per-workspace migration tracking (same pattern as `Migration.apply ~table`)
- Verified end-to-end against live postgres: status → apply → status shows correct timestamps

**Workspace scaffold additions:**
- `.ocamlformat` and `README.md` now generated by `sun new workspace`; total 17 files
- README includes build instructions, run commands, CLI reference, and project layout

**Kafka security layer complete — `Kafka_security` module:**
- New shared module `integrations/kafka/kafka-eio-core/lib/kafka_security.{ml,mli}` — `type t` with `protocol`, `ssl_ca_location`, `sasl_mechanism`, `sasl_username`, `sasl_password`; `default` (Plaintext); `of_env()` reads `KAFKA_SECURITY_PROTOCOL` etc.; `apply conf t` calls `Kafka_raw.conf_set`
- `security : Kafka_security.t` field added to `Kafka_producer.config`, `Kafka_consumer.config`, `Kafka_service.config`, and the internal `Kafka_service.t` handle
- `Kafka_security.of_env()` called from `Kafka_service.config_of_env()` — every production deployment automatically reads security from the environment
- All test files updated: `security = Kafka_security.default` in integration tests for producer, consumer, service; `fake_config` in sun-worker tests; both demo binaries
- Build clean (`dune build` zero errors); 9/9 unit tests pass

**Orientation improvements:**
- README.md: "Security on Day 1" and "Dev mirrors prod exactly" added to Design Principles
- CLAUDE.md: "Current development focus" updated; `Kafka_security` entry added to key design decisions; "Core design principles every engineer must know" section added

## Next Up

**Step 3 — `sun up`** (template-based v1, design locked):
- Scan `app/<domain>/<name>-{svc,worker,fn}/` for Dockerfiles
- Docker build + push to `localhost:5000/<workspace>/<name>:<git-sha>`
- Render YAML from embedded string templates (not a typed AST — that's Phase 6)
- `kubectl apply --dry-run=server` validates before live apply
- In-cluster env vars hardcoded: `redpanda.redpanda.svc.cluster.local:9093`, etc.
- Namespace convention: `<workspace>-<domain>`
- See docs/planning/ROADMAP.md Phase 5 Step 3 for the complete locked-down spec

**Step 3 complete — `sun up`** (template-based v1):
- `cmd_up.ml` fully implemented: service discovery, docker build+push, YAML template rendering, `kubectl apply --dry-run=server` validation, live apply
- `type primitive = Svc | Worker | Fn` — inferred from directory suffix (`_svc`, `_worker`, `_fn`)
- Schedule extraction for `_fn`: scans `lib/<name>_fn.ml` for `schedule = "..."` literal; defaults to `"0 * * * *"` if not found
- Namespace convention: `<workspace>-<domain>` (e.g. `venus-comms`)
- k8s name: underscores replaced with hyphens (e.g. `notify_worker` → `notify-worker`)
- Image: `localhost:5000/<workspace>/<k8s_name>:<git_sha>`, tag overridable with `--tag`
- `--dry-run` skips docker build/push and prints YAML to stdout — validated against live venus workspace
- Five cluster env vars injected via ConfigMap: Kafka, schema registry, Postgres, Loki, Pushgateway (in-cluster DNS, verified against live cluster)
- `-svc` manifests include NodePort Service + liveness/readiness probes on `/healthz:8080`
- `-worker` manifests omit ports and probes (Kafka poll loop is the health signal)
- `Deploy_failed` exception halts pipeline at first error with clear message

**Step 4 complete — `sun status`**:
- `cmd_status.ml` fully implemented: discovers domains from `app/`, derives namespaces, checks existence with `kubectl get ns`, shows pods or "(not deployed — run 'sun up')"
- Domain filter arg: `sun status comms` limits to one namespace

**Venus notify_worker now deployable**:
- Added `examples/venus/app/comms/notify_worker/bin/main.ml` — standalone entrypoint wiring Obs, Db, Kafka from env vars; instantiates `Notify_worker.Make` functor with injected dependencies
- Added `examples/venus/app/comms/notify_worker/bin/dune`
- Added `examples/venus/app/comms/notify_worker/Dockerfile` — builds from repo root, `librdkafka1` runtime

**Step 3b complete — Logistics/fulfillment acceptance test (venus)**:
- `examples/venus/events/billing/payment_confirmed.ml` — `Payment_confirmed` event: `payment_id`, `charge_id`, `customer_id`, `amount_cents`, `currency`; library `venus_billing_events`
- `examples/venus/app/logistics/fulfillment_worker/` — `Fulfillment_worker` wired to `Message = Payment_confirmed`; standalone `bin/main.ml` with env-var driven Kafka config; `Dockerfile` for k8s deploy
- `sun up --dry-run` from venus discovers both `comms/notify_worker` and `logistics/fulfillment_worker`; correct namespaces `venus-comms` and `venus-logistics`

**Library naming bug fixed — workspace-prefix all generated library names**:
- Root cause: `sun new event/worker/svc/fn` generated bare library names (e.g., `billing_events`) that collide when two workspaces coexist in the same dune build graph
- Fix: `ws_of_cwd () = norm (Filename.basename (Sys.getcwd ()))` added to `cmd_new.ml`; all four `new_*` functions prefix `lib` with workspace name:
  - `new_event`: `lib = ws ^ "_" ^ team ^ "_events"` (e.g., `acme_billing_events`, `venus_billing_events`)
  - `new_worker`: `lib = ws ^ "_" ^ domain ^ "_" ^ name ^ "_worker"` (e.g., `venus_logistics_fulfillment_worker`)
  - `new_svc`: `lib = ws ^ "_" ^ domain ^ "_" ^ name ^ "_svc"`
  - `new_fn`: `lib = ws ^ "_" ^ domain ^ "_" ^ name ^ "_fn"`
- Output message from `sun new event` now correctly shows `(libraries venus_billing_events)`
- Both acme and venus coexist in full `dune build` with no name collisions

**Full e2e CLI acceptance test passed**:
- `sun new workspace acme` → 17 files → `dune build acme/` → clean
- From inside acme: `sun new event billing/payment_confirmed` + `sun new worker logistics/fulfillment` + `sun new svc ops/admin` + `sun new fn billing/invoice` → all build clean in single monorepo alongside venus
- `sun up --dry-run` from acme discovers all 5 services: `[worker] logistics/fulfillment_worker`, `[worker] comms/notify_worker`, `[svc] payments/charge_svc`, `[fn] billing/invoice_fn`, `[svc] ops/admin_svc`
- CronJob schedule `"0 * * * *"` extracted from fn source via literal scan

**Live `sun up` against venus — all pods Running (k3d cluster `sun-local`)**:
Ran `sun up` from `examples/venus/` against the live k3d cluster and discovered 6 real issues fixed in sequence:
1. **Namespace dry-run order**: Server-side dry-run fails if namespace doesn't exist yet. Fix: split manifest — apply namespace first (cluster-scoped, idempotent, always safe), then dry-run+apply workload resources against the now-existing namespace.
2. **Registry hostname split**: k3d's `registries.yaml` maps `sun-registry:5000` inside the cluster, but host pushes via `localhost:5000`. Fix: `push_image = localhost:5000/...`, `cluster_image = sun-registry:5000/...`; manifest references use `cluster_image`.
3. **`imagePullPolicy: Always`**: k3d/containerd caches images by tag, so re-pushing the same tag doesn't trigger a fresh pull. Fixed by adding `imagePullPolicy: Always` to all generated Deployments and CronJobs.
4. **GLIBC mismatch**: Binary compiled on Ubuntu 24.04 (GLIBC 2.39) but `debian:bookworm-slim` only has 2.36. Fixed by changing Dockerfile base to `ubuntu:24.04` in template and existing venus Dockerfiles.
5. **Missing `libpq5`**: `notify_worker` links against PostgreSQL client (`caqti-driver-postgresql` → `libpq.so.5`). Added `libpq5` to the Dockerfile template alongside `librdkafka1`.
6. **Migrations in-cluster**: Worker called `Migration.apply ~dir:"examples/venus/db/migrations"` (relative path, doesn't exist in container). Fixed: migrations dir now configurable via `MIGRATIONS_DIR` env var; skipped when env var is absent. Cluster workers connect to DB but don't run migrations — that's `sun migrate`'s job.
7. **`sun status` output order**: `Printf.printf` is OCaml-buffered, `Sys.command` writes directly to OS stdout. "Namespace:" header appeared after pod table. Fixed by adding `%!` flush before each `Sys.command` call.

Final state: `fulfillment-worker` and `notify-worker` both `1/1 Running`; consumer groups `venus-logistics-fulfillment-worker` and `comms-notify-worker` both **Stable** in Redpanda (verified via `rpk group list`). Logs ship to Loki (LOKI_URL set in ConfigMap).

**`sun status` NodePort port-forward hint** — NodePort service detection switched from `--field-selector spec.type=NodePort` (unsupported by kubectl for Services) to jsonpath filter: `'{.items[?(@.spec.type=="NodePort")].metadata.name}'`. Prints `→ kubectl port-forward svc/<name> -n <namespace> 8080:80` after pods table when a NodePort service is present.

**Full pluto e2e end-to-end verified** (sun new workspace → sun up → sun migrate → live API calls):

Workspace scaffold was extended to include DB integration by default: `sun new workspace pluto` now generates 19 files including a shared `lib/notification.ml` storage module (used by both svc and worker), `lib/dune` (pluto_storage library), and `db/migrations/0001_notifications.sql`. The scaffold wires:
- `app/payments/charge_svc`: `POST /charges` writes to DB; `GET /notifications` reads from DB
- `app/comms/notify_worker`: consumes `Charged` Kafka events, writes to DB via `Notification.insert`
- Both services wire Obs (Loki + Prometheus) with `~backend:(Obs.compose log_backend prom)` and `Obs.with_context`
- `MIGRATIONS_DIR` env var: workers skip migrations when absent (migrations are `sun migrate`'s job)

Verified sequence:
1. `sun new workspace pluto` → 19 files; `dune build examples/pluto/` → clean
2. `sun up` from examples/pluto/ → both pods `1/1 Running`; `sun status` shows port-forward hint
3. `sun migrate` → auto-detects cluster postgres, forks `kubectl port-forward` background process, applies `0001_notifications.sql`
4. `kubectl port-forward svc/charge-svc -n pluto-payments 8080:80`
5. `curl localhost:8080/health` → `ok`
6. `curl -X POST localhost:8080/charges` × 2 → `{"id":"ch_XXXXXX","accepted":true}`; both written to DB
7. `curl localhost:8080/notifications` → returns stored charges as JSON array

**Quickstart documentation written** — README.md §Quickstart: complete five-minute tutorial covering `sun dev up` → `sun new workspace` → `sun up` → `sun migrate` → API calls → Grafana. Includes scaffold structure table and "Adding a new domain" commands.

## Phase 5 — CLI Complete

All Phase 5 deliverables are done:

| Command | Status |
|---------|--------|
| `sun new workspace <name>` | ✓ |
| `sun new svc/worker/fn/event` | ✓ |
| `sun dev up/down/status` | ✓ |
| `sun up [--dry-run] [--tag]` | ✓ |
| `sun status [domain]` | ✓ |
| `sun migrate [status\|rollback]` | ✓ |

## Phase 6 — Production Deployment Pipeline (complete)

### `sun deploy` command

New `cli/sun/bin/cmd_deploy.ml`:
- `--image-tag <sha>` — image tag to deploy (defaults to short git SHA)
- `--registry <url>` — production container registry (ECR, Artifact Registry, Docker Hub); omit for local k3d
- `--emit-to <dir>` — GitOps mode: write per-service YAML files instead of applying to the cluster
- `--dry-run` — print YAML to stdout without applying

YAML rendering logic extracted from `cmd_up.ml` into `cli/sun/lib/sun_cli_manifest.ml` (new library module) so both commands share it. `Sun_cli_manifest` exports `discover_services`, `render`, `apply`, `emit_to_dir`, and all template helpers. Added `unix` to `cli/sun/lib/dune` deps for `Unix.mkdir` in `emit_to_dir`.

Verified end-to-end:
- `sun deploy --dry-run` → correct YAML with `sun-registry:5000` image refs
- `sun deploy --emit-to /tmp/pluto-manifests --image-tag abc1234 --registry 123456789.dkr.ecr.us-east-1.amazonaws.com` → wrote `pluto-comms-notify-worker.yaml` and `pluto-payments-charge-svc.yaml`; `image:` field contains `123456789.dkr.ecr.us-east-1.amazonaws.com/pluto/charge-svc:abc1234` ✓

### Terraform modules

**`platform/infra/base/`** — cluster-agnostic Helm bootstrap (any k8s):
- cert-manager (CRDs, Let's Encrypt staging + prod `ClusterIssuer`)
- ingress-nginx (LoadBalancer or NodePort)
- Argo CD + Ingress at `argocd.<base_domain>`
- Redpanda (configurable replicas, CPU, memory, persistent volumes)
- PostgreSQL via Bitnami chart (optional — set `install_postgresql=false` for RDS/Cloud SQL)
- Loki + Grafana stack + Ingress at `grafana.<base_domain>`
- Prometheus + Pushgateway

**`platform/infra/aws/`** — EKS cluster provisioning:
- VPC module (public + private subnets, 3 AZs, single or HA NAT gateway)
- EKS managed node group (configurable instance types, min/max/desired size)
- ECR repositories (one per service, `for_each` over `var.ecr_repositories`)
- ECR lifecycle policy (keep last 30 images)
- RDS PostgreSQL 16 (encrypted, private subnet, backup retention 7 days)
- Route53 hosted zone
- cert-manager IRSA role (IAM policy for Route53 DNS01 challenge solving)
- Outputs: `kubeconfig_command`, `ecr_registry`, `ecr_login_command`, `postgres_url`, `cert_manager_irsa_arn`

**`platform/infra/gcp/`** — GKE Autopilot cluster provisioning:
- Custom VPC with secondary ranges for GKE pods/services
- Cloud Router + NAT
- GKE Autopilot cluster (private nodes, REGULAR release channel)
- Artifact Registry repository
- IAM binding: GKE node SA → `artifactregistry.reader`
- Cloud SQL PostgreSQL 16 (private IP, configurable tier + HA)
- Private service connection for Cloud SQL
- Cloud DNS managed zone
- Outputs: `kubeconfig_command`, `artifact_registry`, `docker_auth_command`, `postgres_url`

### CI/CD reference workflows

**`platform/infra/ci/github-actions-deploy.yml`** — direct deploy mode:
1. Build OCaml binaries, build + push Docker images to ECR
2. `sun deploy --image-tag $SHA --registry $ECR_REGISTRY`
3. `sun status`

**`platform/infra/ci/github-actions-gitops.yml`** — GitOps mode:
1. Build + push images to ECR
2. `sun deploy --emit-to manifests/ --image-tag $SHA`
3. Commit + push `manifests/*.yaml` to separate GitOps repo
4. Argo CD reconciles cluster

**`platform/infra/argocd/application.yaml`** — Argo CD `Application` manifest (one-time cluster setup):
- `syncPolicy.automated.prune = true` — removes resources deleted from GitOps repo
- `syncPolicy.automated.selfHeal = true` — reverts manual kubectl changes
- `ServerSideApply=true` — handles multi-owner field management

### Documentation

`docs/guides/TUTORIAL.md` §CLI reference updated with `sun deploy` flags. New §Part 8 — Production deployment covers:
- Direct deploy and GitOps deploy modes
- AWS (EKS) and GCP (GKE) provisioning commands
- `platform/infra/base/` platform bootstrap
- Argo CD one-time setup

## Current State — Phase 6 Complete

The production deployment pipeline is complete. All Phase 6 deliverables are done:

| Deliverable | Status |
|---|---|
| `Sun_cli_deployment_plan` — typed deployment plan | ✓ |
| `Sun_cli_env_target` — `Local_k3d`, `Customer_k8s_direct`, `Customer_k8s_gitops`, `Sun_hosted` | ✓ |
| `Sun_cli_executor` — `local`, `direct`, `gitops` executors | ✓ |
| `sun deploy --image-tag --registry --emit-to --dry-run` | ✓ |
| `sun deploy --emit-plan-to FILE` — plan JSON serialization | ✓ |
| `Sun_cli_toml` — `sun.toml` parser (scale, env, deploy, labels) | ✓ |
| `platform/infra/aws/`, `platform/infra/gcp/`, `platform/infra/base/` Terraform modules | ✓ |
| Argo CD `Application` manifest + GitOps emit mode | ✓ |
| `docs/deployment/escape-hatches.md` — four-level escape hatch hierarchy | ✓ |
| `docs/deployment/self-hosted-substrate-contract.md` | ✓ |
| CI workflow references (`platform/infra/ci/`) | ✓ |

## Phase 7 — Core deliverables complete

| Ticket | Description | Status |
|---|---|---|
| FEAT-010 | Sun-hosted executor spike | ✓ DONE |
| FEAT-011 | Argo Rollouts canary/blue-green support | ✓ DONE |
| FEAT-012 | CI workflow scaffold in `sun new workspace` | ✓ DONE |
| FEAT-013 | Docs aligned with implementation reality | ✓ DONE |
| FEAT-014 | Sun-hosted secret management | ✓ DONE |
| FEAT-016 | Hosted account/environment model | ✓ DONE |
| FEAT-018 | Hosted executor (full impl) | ✓ DONE |
| FEAT-015 | Hosted release inspection and diagnostics | BACKLOG — blocked on DEC-007 |
| FEAT-017 | Hosted default URLs and custom-domain flow | BACKLOG — blocked on DEC-005 |

**Note on `sun.toml` parsing:** `Sun_cli_toml` is fully implemented and reads all supported fields from user files. `[infra.rollout]` canary/blue-green is now backed by Argo Rollouts manifest synthesis (FEAT-011). Remaining unimplemented `sun.toml` fields: `[infra.kafka]` extra topics, `secrets` in `[infra.env]`.

**Kafka security wiring to C — verify `apply` correctness with live cluster:**
- `Kafka_security.apply` calls `Kafka_raw.conf_set`; verified at compile time; exercise with a SASL-authenticated Redpanda to confirm end-to-end
- TLS dev gap: Redpanda in k3d runs with `tls.enabled=false` because cert-manager CRDs aren't provisioned in the dev cluster; this is a documented conscious choice, not an oversight — production deployments set `KAFKA_SECURITY_PROTOCOL=ssl` and the code picks it up automatically

---

## Files

| File | Status |
|---|---|
| `integrations/observability/obs-eio/lib/obs_trace.ml/.mli` | Complete |
| `integrations/observability/obs-eio/lib/obs_metrics.ml/.mli` | Complete |
| `integrations/observability/obs-eio/lib/obs.ml/.mli` | Complete — added `context` field to `span_event` |
| `integrations/observability/obs-eio/test/test_obs.ml` | Complete — 18 tests |
| `integrations/observability/obs-eio-loki/lib/obs_loki.ml/.mli` | Complete |
| `integrations/observability/obs-eio-loki/test/test_loki.ml` | Complete — 8 tests |
| `integrations/observability/obs-eio-loki/obs-eio-loki.md` | Complete — spec |
| `platform/local/scripts/ensure-loki.sh` | Complete |
| `platform/local/scripts/ensure-grafana.sh` | Complete |
| `integrations/observability/obs-eio/lib/obs.ml/.mli` | Updated — added `help` field to `metric_event` |
| `integrations/observability/obs-eio-prometheus/lib/obs_prometheus.ml/.mli` | Complete |
| `integrations/observability/obs-eio-prometheus/test/test_prometheus.ml` | Complete — 10 tests |
| `platform/local/scripts/ensure-pushgateway.sh` | New |
| `platform/local/scripts/ensure-prometheus.sh` | New — also provisions Prometheus datasource in Grafana |
| `platform/local/config/prometheus.yml` | New — 5s scrape interval, Pushgateway target |
| `docs/planning/ROADMAP.md` | Updated — prometheus done, HTTP service layer next |
| `framework/sun-svc/lib/auth.ml/.mli` | Complete |
| `framework/sun-svc/lib/response.ml/.mli` | Complete |
| `framework/sun-svc/lib/request.ml/.mli` | Complete |
| `framework/sun-svc/lib/route.ml/.mli` | Complete |
| `framework/sun-svc/lib/service.ml/.mli` | Complete |
| `framework/sun-svc/test/test_routing.ml` | Complete — 10 tests |
| `framework/sun-svc/test/test_auth.ml` | Complete — 11 tests |
| `framework/sun-svc/test/test_service.ml` | Complete — 11 tests |
| `framework/sun-svc/sun-svc.md` | Complete — design spec |
| `framework/sun-fn/lib/fn.ml/.mli` | Complete |
| `framework/sun-fn/lib/dune` | Complete |
| `framework/sun-fn/test/test_fn.ml` | Complete — 7 tests |
| `framework/sun-fn/sun-fn.md` | Complete — design spec |
| `dune-project` | New root project (merged obs + http) |
| `framework/sun-svc/lib/service.ml` | Updated — `?ot:Obs.t`, `?route_observer`, per-request metrics |
| `framework/sun-svc/lib/service.mli` | Updated — `?ot:Obs.t` exposed |
| `framework/sun-svc/lib/dune` | Updated — added `obs_eio` dep |
| `framework/sun-svc/test/test_service.ml` | Updated — 2 new metrics tests (13 total) |
| `framework/sun-svc/test/dune` | Updated — added `obs_eio obs_eio_prometheus` deps |
| `framework/sun-worker/lib/worker.ml/.mli` | Complete |
| `framework/sun-worker/lib/dune` | Complete |
| `framework/sun-worker/test/test_worker.ml` | Complete — 7 tests |
| `framework/sun-worker/test/dune` | Complete |
| `framework/sun-worker/sun-worker.md` | Complete — design spec |
| `integrations/kafka/dune-project` | Deleted — merged kafka into root project |
| `examples/local-demo/lib/events.ml` | Complete — OrderPlaced message contract |
| `examples/local-demo/lib/dune` | Complete |
| `examples/local-demo/bin/demo.ml` | Complete — orchestrated e2e demo |
| `examples/local-demo/bin/dune` | Complete |
| `examples/local-demo/FRICTION_LOG.md` | Complete — 7 friction items |
| `http/` → `framework/` | Renamed — updated CLAUDE.md, README, ROADMAP, WORK_SUMMARY |
| `integrations/storage/sun-storage/lib/storage_error.ml/.mli` | Complete |
| `integrations/storage/sun-storage/lib/db.ml/.mli` | Complete |
| `integrations/storage/sun-storage/lib/migration.ml/.mli` | Complete |
| `integrations/storage/sun-storage/lib/table.ml/.mli` | Complete |
| `integrations/storage/sun-storage/test/test_storage.ml` | Complete — 8 tests |
| `integrations/storage/sun-storage/sun-storage.md` | Complete — design spec |
| `platform/local/scripts/ensure-postgres.sh` | New |
