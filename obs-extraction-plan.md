# obs-eio extraction plan

Working position:

`obs-eio` is not a thin Eio wrapper over existing observability packages. It is a small Eio-native observability core with custom Loki and Prometheus backends.

That is defensible if the extraction keeps the core small, tests the protocol details, and does not claim to replace existing packages such as `prometheus-eio`.

## Recommended order

1. Finish `kafka-eio` 0.1 first.

   Freeze the `Kafka` namespace, hide `Kafka_raw`, fix tombstones/null headers, add config `extra`, and verify the `audit2.md` release checklist.

2. Audit observability in place.

   Draft `obs-audit.md` while the code still lives under `sun/integrations/observability`. The audit should decide package names, public module shape, dependency split, and protocol correctness.

3. Extract after the audit bar is met.

   Move only the clean packages into standalone OPAM-ready repos once public APIs and tests are stable.

## Package shape

Preferred OPAM package names:

```text
obs-eio
obs-loki-eio
obs-prometheus-eio
```

Preferred public modules:

```ocaml
Obs
Obs_loki
Obs_prometheus
```

Keep `obs-eio` installable without Loki/Prometheus/network exporter dependencies.

## Positioning

Use this framing:

> A unified Eio-native telemetry suite for metrics, logs, and traces, with fiber-aware context and switch-scoped exporter lifetimes.

Avoid claiming `obs-prometheus-eio` is the canonical Eio Prometheus package. `prometheus-eio` already exists; this package is the Prometheus backend for `Obs.backend`.

## Pre-extraction audit criteria

### Core (`obs-eio`)

- [ ] Core has no Loki/Prometheus/HTTP exporter dependency.
- [ ] `Obs.t` lifecycle and concurrency contract is documented.
- [ ] Trace context propagation is W3C `traceparent` compatible.
- [ ] Ambient context behavior is explicit: immutable handle copy, no hidden global mutable state.
- [ ] Backend failures cannot crash application code unless explicitly configured to do so.

### Prometheus backend (`obs-prometheus-eio`)

- [ ] Decide whether to stay custom or reuse `prometheus`/`prometheus-eio`.
- [ ] Formatting compliance: labels escape `"`, `\`, and newlines correctly.
- [ ] Metric names and label names follow Prometheus regex rules.
- [ ] `# HELP` and `# TYPE` lines precede metric samples.
- [ ] Histogram buckets are cumulative, sorted ascending, and include `+Inf`.
- [ ] Scrape rendering snapshots state without holding locks during formatting.
- [ ] Pushgateway failures and timeouts return errors and never crash app code.
- [ ] Push/scrape paths are tested with concurrent metric emission.

### Loki backend (`obs-loki-eio`)

- [ ] Payload JSON matches Loki push API shape.
- [ ] Timestamps are nanosecond strings.
- [ ] Stream labels are low-cardinality and validated.
- [ ] Loki 3 structured metadata is emitted and tested.
- [ ] Non-2xx responses are reported without raising through app code.
- [ ] Network failures and timeouts are bounded.
- [ ] Buffering/backpressure policy is explicit: synchronous push, bounded buffer, drop policy, or blocking policy.

## What not to do yet

- Do not add `logs`, `opentelemetry`, or `prometheus-eio` blindly.
- Do not rename modules to `Obs_loki_eio` / `Obs_prometheus_eio` unless a non-Eio backend is actually planned.
- Do not extract before deciding whether Prometheus text rendering stays custom.
- Do not make a broad "canonical observability for OCaml" claim; claim Eio-native `Obs.backend` integration.

## Extraction checklist

- [ ] Dune packages are split cleanly.
- [ ] OPAM names and public library names are final.
- [ ] `obs-eio` has minimal dependencies.
- [ ] Backend packages depend on `obs-eio`, not on Sun framework packages.
- [ ] Tests pass from a clean checkout.
- [ ] Live Loki/Prometheus tests are gated by env vars.
- [ ] README examples do not reference Sun internals unless explicitly marked as Sun integration examples.
