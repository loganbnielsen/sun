# obs-eio audit

Independent extraction audit for:

- `integrations/observability/obs-eio`
- `integrations/observability/obs-eio-loki`
- `integrations/observability/obs-eio-prometheus`

Goal: decide what must be fixed before these can become standalone OPAM packages, not what an ideal observability platform might eventually contain.

Baseline: code currently lives inside `sun`; this audit treats the packages as future independent building blocks.

Focused tests pass:

```text
dune test integrations/observability/obs-eio/test integrations/observability/obs-eio-loki/test integrations/observability/obs-eio-prometheus/test
```

## Status (2026-08-25)

All 10 pre-extraction blockers below are addressed — see the "Pre-extraction blockers"
list for how each was resolved (fixed, or documented per this audit's own "smaller
path" recommendation). 96 tests pass across all three packages, including new coverage
for the negative-counter guard, `"le"` label rejection, backend-exception isolation,
HELP-text escaping, and the help-text-mismatch warning.

Not yet done — this was deliberately deferred, not overlooked: the "Packaging" and
"Extraction checklist" items below (standalone `dune-project`/opam files, `public_name`
stanzas, actually moving the trees out of `sun`). Blocker-fixing and extraction were
kept as separate passes on purpose.

## Short version

The core idea is good: `obs-eio` is not a thin wrapper over `logs`, `prometheus`, or OpenTelemetry. It is a small Eio-native event model with `Obs.backend` sinks. That gives Sun a unified span/log/metric capability without forcing every service to stitch together unrelated packages.

The extraction blockers are not about adding more features. They are about making the custom protocol code and public promises honest.

Pre-extraction blockers — all resolved (2026-08-25):

1. **Fixed by deletion.** `Obs.register_histogram`'s `?buckets` param is gone; buckets are backend-defined (`obs-eio-prometheus`'s `default_bounds`), documented as such. The smaller honest API, per this audit's own recommendation.
2. **Fixed in docs.** `obs-eio-loki.md` and `obs_loki.mli` now describe the actual 2-element payload and logfmt trace fields, with the compatibility rationale (Loki 2.x support) and updated LogQL examples (`| logfmt` before filtering on `trace_id`).
3. **Fixed.** `escape_help_text` escapes backslash and newline in `# HELP` lines; tested.
4. **Fixed.** `register_counter`'s emitter raises `Invalid_argument` on a negative delta; tested.
5. **Fixed.** `register_histogram` raises `Invalid_argument` if `label_names` includes `"le"`; tested.
6. **Documented**, not code-changed, per this audit's own "smaller 0.1 path": `obs_loki.mli` and `obs-eio-loki.md` now state the span-close-timestamp semantics explicitly.
7. **Fixed.** `Obs_tls` no longer lives in `obs-eio` core (now just `eio`, `mtime`). Duplicated as `Obs_loki_tls` / `Obs_prometheus_tls` into each backend package (distinct names — two libraries can't both unwrap-export a module named plain `Obs_tls` without a link clash the moment something depends on both, which every Sun service composing Prometheus+Loki does). `kafka-eio-service` was a third, previously-undocumented consumer riding on `obs_eio`'s leaked `Obs_tls`; it now has its own private `Kafka_service_tls` copy instead.
8. **Improved**, not fully resolved: `Obs_trace.generate` now draws from a self-seeded `Random.State.t` private to the module, so trace/span IDs no longer depend on a caller remembering `Random.self_init ()` (forgetting it previously meant every process shared the stdlib `Random` module's fixed default seed — a real collision risk, not just weak crypto). Still not cryptographically strong; documented as such.
9. **Fixed.** `Obs.compose` wraps each sibling backend's `emit_span`/`emit_metric` independently (one raising can't block delivery to the other), and `with_span`/`register_counter`/`register_gauge`/`register_histogram` wrap their own backend call the same way (a raising backend can't crash application code). Tested for both compose isolation and direct-backend isolation.
10. **Fixed.** `obs-eio-loki.md` and `obs-eio-prometheus.md` no longer claim HTTPS is out of scope or that Pushgateway push is unimplemented; both now document what's actually there (including the Prometheus `push`-is-deferred framing, which was already accurate — only its `~buckets` example was stale).

Prometheus backend review's item 9 (family metadata conflicts) is now partly enforced too:
a same-name registration with a different `help` string is logged and the first `help`
wins, matching the existing kind-conflict pattern. A divergent `label_names` set across
registrations under the same name is still undetected — `Obs.t` has no cross-registration
registry of declared label names to check that against, and adding one wasn't cheap
enough to justify here.

Explicit deferrals:

1. Do not add `logs`, `opentelemetry`, `prometheus`, or `prometheus-eio` blindly.
2. Do not add async Loki batching before extraction unless synchronous push latency is unacceptable for intended users.
3. Do not add a built-in `/metrics` server; keep renderer-only unless a separate service helper needs it.

## Current dependency shape

`obs-eio`:

```text
eio, eio.unix, unix, mtime, uri, tls-eio, x509, domain-name, ptime
```

This is too heavy for the core package. The extra URI/TLS/X509/Ptime dependencies come from `Obs_tls`, which only HTTP exporters need.

`obs-eio-loki`:

```text
obs-eio, eio, unix, cohttp-eio, uri, http, yojson
```

`obs-eio-prometheus`:

```text
obs-eio, eio, unix, cohttp-eio, http, uri
```

These packages use transport/support libraries, not existing observability-domain packages. That is acceptable if protocol correctness is tested.

## Package shape

Recommended OPAM package names:

```text
obs-eio
obs-loki-eio
obs-prometheus-eio
```

Recommended public modules:

```ocaml
Obs
Obs_loki
Obs_prometheus
```

Do not rename modules to `Obs_loki_eio` or `Obs_prometheus_eio` unless a non-Eio backend is actually planned.

Keep `obs-eio` free of Loki/Prometheus/HTTP exporter dependencies.

Target package dependencies:

```text
obs-eio:
  ocaml, dune, eio, mtime

obs-loki-eio:
  obs-eio, eio, cohttp-eio, http, uri, yojson
  + tls-eio, x509, domain-name, ptime if HTTPS support stays here

obs-prometheus-eio:
  obs-eio, eio, cohttp-eio, http, uri
  + tls-eio, x509, domain-name, ptime if Pushgateway HTTPS support stays here
```

## Core API review

What is good:

1. `Obs.t` is immutable; `with_context` returns a derived handle instead of mutating global state.
2. Span close uses `Fun.protect`, so spans close on application exceptions.
3. Trace propagation uses W3C `traceparent` strings and case-insensitive extraction.
4. Metric names and label names are validated before emission.
5. Label sets are checked for missing, extra, and duplicate labels before backend calls.

Blockers:

1. Backend exceptions are not isolated by the core.

   `Obs.with_span` calls `t.backend.emit_span` in `finally`. If a custom backend raises, that exception can escape during span close. `Obs.compose` also calls backend `a` then backend `b` directly; if `a` raises, `b` is skipped.

   Recommendation: either document that backends must never raise and keep current behavior, or wrap backend calls in `try ... with` at the core fan-out boundary. For a reusable package, prefer protecting `compose`.

2. Counter deltas can be negative.

   `counter_fn` is `int -> unit`, and `register_counter` accepts any int. Prometheus counters are monotonic. A negative delta produces invalid semantics.

   Recommendation: reject negative counter deltas in `register_counter` emitters.

3. Histogram label names can include `le`.

   Prometheus histograms synthesize an `le` label for buckets. The shared label validator currently allows users to register `le` as a normal histogram label, which creates duplicate/confusing labels at render time.

   Recommendation: reject `le` in `register_histogram ~label_names`.

4. Histogram bucket configuration is discarded.

   `register_histogram ?buckets` accepts buckets, but `Obs.metric_event` carries only `` `Histogram of float `` and `Obs_prometheus` always uses `default_bounds`.

   Recommendation: either remove `?buckets` before extraction or carry bucket metadata through registration into the backend. Deletion is the smaller honest API if custom buckets are not needed yet.

5. `Obs_tls` does not belong in the core package.

   `Obs_tls` is useful shared adapter code, but it drags `uri`, `tls-eio`, `x509`, `domain-name`, `ptime`, `unix`, and `eio.unix` into `obs-eio`.

   Recommendation: move TLS helper code into `obs-loki-eio` and `obs-prometheus-eio`, or a tiny private support library used only by HTTP backends.

6. Trace ID generation is too weakly specified.

   `Obs_trace.generate` uses `Random.int64` and asks callers to run `Random.self_init ()`. That is fine for local correlation, but weak for a public tracing package.

   Recommendation: scope `Obs_trace` as lightweight W3C propagation only, or switch to a stronger randomness source before claiming production tracing semantics.

## Prometheus backend review

What is good:

1. The renderer snapshots under `Mutex` and formats after releasing it.
2. Label values escape `\`, `"`, and newlines.
3. Histogram counts are cumulative and include `+Inf`.
4. Pushgateway calls are bounded by a 5 second timeout and return `(unit, string) result`.
5. Empty renderer output returns `Ok ()` without network I/O.

Blockers:

1. HELP text is not escaped.

   `render` writes `# HELP <name> <help>` directly. Prometheus text exposition requires escaping backslash and newline in HELP docstrings.

   Recommendation: add a HELP escaping function and tests for newline/backslash.

2. Custom buckets are documented but ignored.

   This is shared with core. The docs show `~buckets:[...]`, but rendered histograms always use `default_bounds`.

   Recommendation: remove custom bucket docs/API or implement real propagation.

3. Family metadata conflicts are under-modeled.

   The backend detects kind conflicts, but the same metric name can be registered with different help text or different expected label names. That can produce confusing output.

   Recommendation: before extraction, document the rule: one metric name maps to one kind/help/label set. Enforce it if the current API can do so cheaply.

4. Histogram labels can conflict with `le`.

   This is shared with core. Do not render a user-provided `le` label and the bucket `le` label in the same sample.

Deferrals:

1. Reusing `prometheus` or `prometheus-eio`.

   Because `obs-prometheus-eio` is an `Obs.backend` bridge, custom rendering can stay if tests cover the text format. `prometheus-eio` exists on OPAM, so position this as the Prometheus backend for `Obs.backend`, not as the base Eio Prometheus package. Revisit dependencies only if using existing packages deletes more code than it adds.

2. Built-in HTTP scrape server.

   The `(unit -> string)` renderer is enough. A server helper can live in Sun or a later package.

## Loki backend review

What is good:

1. Uses `cohttp-eio` and `Yojson` instead of raw HTTP/string JSON.
2. Non-2xx, timeouts, and connection exceptions are caught and logged to stderr.
3. Stream label names reuse `Obs.label_name` validation.
4. The push body has the standard Loki `streams`/`stream`/`values` shape.
5. HTTPS support exists through `Obs_tls.https_for_uri`.

Blockers:

1. Docs claim Loki 3 structured metadata, but code does not emit it.

   `loki_push_body` renders each entry as `[timestamp, line]`. The docs claim `[timestamp, line, metadata]`. The code intentionally puts `trace_id` and `span_id` into the logfmt line for Loki 2 compatibility.

   Recommendation: choose one contract before extraction. The lazy extraction path is to document the current 2-element payload and logfmt trace fields. Add structured metadata later behind an explicit option if needed.

2. Docs say HTTPS is out of scope, but code supports HTTPS.

   Update docs. Do not remove working HTTPS.

3. Synchronous push can delay application span close.

   `emit_span` performs one HTTP POST per span and can block up to 5 seconds. It catches errors, so failures should not crash the app, but latency is paid by application code.

   Recommendation: document this as the 0.1 behavior. Add batching only if this is unacceptable for target users.

4. All log entries in a span share one timestamp.

   `Obs_loki.emit_span` computes one wall-clock timestamp at span close and reuses it for every log entry in the span. That is simple, but long spans and repeated identical lines can have misleading ordering/dedup behavior.

   Recommendation: either document "span-close timestamp" semantics, or carry per-log-entry timestamps in `Obs.log_entry`. Documenting is the smaller 0.1 path.

5. No explicit buffering/backpressure policy.

   Current policy is "no buffer; push synchronously; timeout after 5s; log failures". That is valid if documented.

   Recommendation: put that sentence in the `.mli` and README.

Deferrals:

1. Async batching.

   A switch-owned bounded queue and flush fiber is useful later, but it creates real lifecycle complexity. Do not add it just to look production-y.

2. Loki structured metadata.

   Add when the deployment target is Loki 3-only or when a compatibility flag is designed.

## Documentation blockers

1. `obs-eio-loki.md` is stale:

   - claims structured metadata;
   - says HTTPS/TLS is out of scope;
   - suggests LogQL without `| logfmt` for trace field filtering.

2. `obs-eio-prometheus.md` is stale:

   - says `push` is deferred, but `Obs_prometheus.push` exists;
   - documents custom buckets that are ignored.

3. Package positioning needs one clear sentence:

   ```text
   obs-eio is a small Eio-native observability event model with built-in backend adapters, not a replacement for every OCaml observability package.
   ```

## Test checklist before extraction

Core:

- [x] Backend exception behavior is tested and documented.
- [x] Negative counter deltas are rejected.
- [x] Histogram label name `le` is rejected.
- [x] Histogram bucket API is removed (deletion over end-to-end testing of a feature nothing used).

Prometheus:

- [x] HELP strings escape backslash and newline.
- [x] Label escaping tests remain.
- [x] Histogram cumulative bucket tests remain.
- [x] Metric family conflict behavior is tested (kind conflicts, pre-existing; help-text mismatch, new).
- [x] Pushgateway non-2xx and timeout tests remain.

Loki:

- [x] Payload shape test matches the documented 2-element value tuple contract.
- [x] Trace field query docs match the payload contract.
- [x] Timestamp semantics are documented: span-close timestamp, shared by every log entry in the span.
- [x] HTTPS URL behavior is documented (system CA bundle, refuses to connect without one); not covered by a live HTTPS-Loki integration test.
- [x] Non-2xx and unreachable tests remain.
- [x] Synchronous timeout behavior is documented (5s).

Packaging — deliberately not started this pass (see Status above):

- [ ] Standalone package metadata exists; current tree only has the root `sun.opam`.
- [ ] Standalone `dune-project` declares `obs-eio`, `obs-loki-eio`, and `obs-prometheus-eio` packages.
- [ ] Libraries have `(public_name ...)` for installable OPAM libraries.
- [x] Backend packages depend on `obs-eio`, not Sun framework packages.
- [x] `obs-eio` has no `cohttp-eio` or `yojson` dependency.
- [x] `obs-eio` does not depend on HTTP/TLS packages — moved out to each backend package (`Obs_loki_tls` / `Obs_prometheus_tls`).
- [x] Live tests are gated by environment variables (`LOKI_URL`, `PUSHGATEWAY_URL`/`PROMETHEUS_URL`) — pre-existing.
- [x] README examples do not require Sun — pre-existing; examples use plain `Eio`/`Obs`, no Sun-specific types.

## Recommended order

1. ~~Fix docs to match current behavior.~~ Done.
2. ~~Decide custom histogram buckets: implement or delete.~~ Done — deleted.
3. ~~Add HELP escaping and negative counter guard.~~ Done.
4. ~~Decide core backend exception policy.~~ Done — `compose` and the direct backend call sites isolate exceptions.
5. ~~Run focused observability tests.~~ Done — 96 tests pass across all three packages.
6. Only then extract packages. **← next step.**

This is mostly cleanup and honesty work. Avoid adding new transport abstractions until the existing behavior is accurately specified and tested.
