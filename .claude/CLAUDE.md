# Sun — Claude Context

## Current development focus

**Phase 7 core deliverables complete.** `sun deploy` is implemented with `--image-tag`, `--registry`, `--emit-to` (GitOps), and `--dry-run` flags. YAML rendering is shared by `sun up` and `sun deploy`. Terraform modules live at `platform/infra/base/`, `platform/infra/aws/`, and `platform/infra/gcp/`. Remaining hosted-product work is tracked in `project/tickets/`. See `docs/planning/WORK_SUMMARY.md` for full details.

Package: `cli/sun/` — binary at `_build/default/cli/sun/bin/main.exe`.

## Ticket system

Work is tracked in `project/tickets/` using a directory-per-status layout. Each ticket is a markdown file with YAML frontmatter. **The `project/tickets/` directory is only ever modified in the `main` checkout — never inside a worktree branch.**

```
project/tickets/
  BACKLOG/                  ← captured but not yet prioritised
  READY_FOR_ENGINEERING/    ← actionable; pick up with /start
  IN_PROGRESS/              ← worktree exists, work underway
  REVIEW/                   ← work submitted; awaiting /review-worktree
  READY_TO_MERGE/           ← review passed; human merges
  BLOCKED_BY_PERFORMANCE/   ← perf regression; needs fix or sign-off
  DONE/                     ← merged
```

**State machine:** `READY_FOR_ENGINEERING` → `IN_PROGRESS` → `REVIEW` → `READY_TO_MERGE` → `DONE`  
If `/review-worktree` finds issues: back to `READY_FOR_ENGINEERING` (with inline notes; `branch`/`worktree` fields preserved).  
Human moves `READY_TO_MERGE` → `DONE` by merging the PR.

**Ticket frontmatter fields:** `id`, `type` (ux-finding | audit-finding | feature | bug), `severity`, `source`, `branch`, `worktree`.  
Do not add a `status:` field — the directory encodes status.

**Human-judgment gates:** Tickets in `BACKLOG/` may contain `## Open Questions`, `## Decision Required`, or `## Blocked On` sections. Tickets in `READY_FOR_ENGINEERING/` are treated as actionable, so `/work` must stop before creating a worktree if any unresolved decision section or marker remains. Resolve the decision in the ticket body or keep the ticket in `BACKLOG/` until the Remediation is unambiguous.

**Ticket dependencies:** Use a body line near the top of each ticket: `**Depends on:** None.` or `**Depends on:** FEAT-003, EXP-008.` `/work` must verify dependencies before creating a worktree. A `READY_FOR_ENGINEERING` ticket with dependencies not yet in `project/tickets/DONE/` stays blocked.

**Skills that interact with tickets:**
- `/work` — unified entry point; dispatches by state: creates worktrees for `READY_FOR_ENGINEERING`, resumes `IN_PROGRESS`, runs review agent on `REVIEW`
- `/review-worktree` — standalone review gate (called internally by `/work review`); subagents emit JSON, `sundev pipeline review` handles file moves
- `/audit` and `/ux-audit` — materialise new findings into `READY_FOR_ENGINEERING/` (idempotent)

**Performance baseline conflict:** `tools/perf/perf_baseline.json` is set to `merge=ours` in `.gitattributes`. On merge, main's baseline wins; a post-merge perf run determines whether the ticket stays merged or moves to `BLOCKED_BY_PERFORMANCE`.

## Core design principles every engineer must know

**Security on Day 1.** `Kafka_security.t` is a first-class field in every producer, consumer, and service config. `config_of_env()` reads `KAFKA_SECURITY_PROTOCOL`, `KAFKA_SSL_CA_LOCATION`, `KAFKA_SASL_*` from the environment. Dev defaults to `Plaintext`; the type forces all other environments to state their security posture explicitly. Do not add Kafka config anywhere that lacks a `security` field.

**Dev mirrors prod exactly.** `sun dev up` runs the same Helm charts as production at single-replica scale. Port-forwards expose every service at the same address the service code expects. If there's a divergence between dev and prod addressing or configuration, that divergence is a bug.

## What this repo is

Sun is an opinionated OCaml 5 production platform for startups. Kafka layer, observability backends, all three service primitives (`-svc`, `-worker`, `-fn`), storage (PostgreSQL), and CLI scaffold commands are complete.

## Repo layout

```
sun/
  integrations/kafka/                        ← Kafka packages (merged into root dune project)
    kafka-eio-core/lib/         ← FFI + error types + C stubs (shared internal package)
    kafka-eio-producer/lib/     ← public producer API
    kafka-eio-consumer/lib/     ← public consumer API
    kafka-eio-service/lib/      ← schema registry + service orchestration
    kafka-eio-{core,producer,consumer,service}/test/
    kafka-eio-*/kafka-eio-*.md  ← per-package spec docs
  integrations/observability/                ← observability packages
    obs-eio/lib/                ← core API: spans, metrics, trace context
    obs-eio-loki/               ← Loki HTTP push backend
    obs-eio-prometheus/         ← Prometheus exposition backend
    obs-eio-*/obs-eio-*.md      ← per-package spec docs
  framework/                   ← Sun service primitives
    sun-svc/lib/                ← REST API service (routes, auth, metrics)
    sun-worker/lib/             ← Kafka consumer (schema registration, per-message metrics)
    sun-fn/lib/                 ← Scheduled function (Pushgateway push, invocation metrics)
    sun-*/sun-*.md              ← per-package spec docs
  examples/local-demo/                         ← full-stack showcase demo (svc → Kafka → worker)
    lib/                        ← shared event contracts for demo
    bin/demo.ml                 ← orchestrated demo binary
  integrations/kafka/demo/bin/demo.ml        ← Kafka-only produce-then-consume demo
  platform/local/
    scripts/                    ← ensure-broker.sh, ensure-loki.sh, etc.
    k8s/                        ← Kubernetes manifests
  dune-project / dune-workspace ← unified root build
  README.md / docs/planning/ROADMAP.md / docs/planning/WORK_SUMMARY.md  ← project-wide docs
```

## Build

```bash
eval $(opam env)
dune build
```

**Prerequisite:** `sudo apt-get install -y librdkafka-dev`  
**OCaml packages:** `eio`, `eio_main`, `alcotest`, `cohttp-eio`, `yojson`, `base64` (install via `opam install`)

## Tests

```bash
# Unit tests (no broker needed)
eval $(opam env) && dune test framework/ integrations/observability/obs-eio/test/

# Full integration tests (requires Redpanda + Loki running)
bash platform/local/scripts/ensure-broker.sh
bash platform/local/scripts/ensure-loki.sh
KAFKA_BROKERS=localhost:9092 LOKI_URL=http://localhost:3100 dune test --force
```

## Run the demo

```bash
# Start infrastructure
bash platform/local/scripts/ensure-broker.sh
bash platform/local/scripts/ensure-loki.sh
bash platform/local/scripts/ensure-grafana.sh
bash platform/local/scripts/ensure-prometheus.sh

# Run the full-stack demo (svc → Kafka → worker, with Loki logs + Prometheus metrics)
KAFKA_BROKERS=localhost:9092 LOKI_URL=http://localhost:3100 \
  dune exec examples/local-demo/bin/demo.exe

# Then browse to http://localhost:3000 (Grafana)
```

## Key design decisions

- **`Kafka_security` is the transport security module** — lives in `kafka-eio-core/lib/kafka_security.ml`. Every `config` type in producer, consumer, and service carries a `security : Kafka_security.t` field. `Kafka_security.apply conf t` calls `Kafka_raw.conf_set` for `security.protocol`, `ssl.ca.location`, `sasl.*`. Never construct a Kafka config without it.
- **All libraries use `(wrapped false)`** — modules are globally accessible as `Kafka_error`, `Kafka_raw`, etc. (not namespaced under library name).
- **`produce`/`produce_await` take a trailing `()`** — required by OCaml's optional-argument erasure rules since `?key` is the last arg with no positional arg after it.
- **Delivery receipts via pipe** — the C delivery callback writes a `(corr_id, err_code)` struct to a Unix pipe (thread-safe, no OCaml runtime needed from C). A background Eio fiber reads from the pipe and resolves pending promises.
- **Fix blocking C calls at the FFI boundary, not above it** — when a C binding holds the OCaml domain lock during a blocking call, the fix belongs in `kafka_stubs.c`: extract all OCaml values into C locals, call `caml_release_runtime_system()`, run the blocking C function, then `caml_acquire_runtime_system()` before any OCaml allocation. This is the pattern used by `ocaml_rd_kafka_flush`, `ocaml_rd_kafka_consumer_close`, and `ocaml_rd_kafka_consumer_poll`. Do not add workaround layers at the OCaml level (`Eio_unix.run_in_systhread`, `Eio.Time.sleep` polling loops, clock parameters) when the correct fix is a two-line change in the C stub.
- **Consumer poll runs directly in a fiber** — `poll_fiber` calls `Kafka_raw.consumer_poll t.handle 100` directly (no systhread). The C stub releases the OCaml domain lock for the duration of the 100ms block, so the GC can run and Eio delivers `Cancelled` cleanly once the call returns.
- **`Kafka_consumer_handle.t`** — a thin shared type in kafka-eio-core that lets the producer accept a consumer handle in `with_transaction` without creating a circular dependency.

## Error handling

All operations return `(_, Kafka_error.t) result`. Never raise on API calls.  
`Kafka_error.of_int` maps librdkafka integer error codes to typed variants.  
`Kafka_error.to_string` calls `rd_kafka_err2str` via FFI for human-readable messages.

## OCaml version

OCaml 5.4.1, Eio 1.3, dune 3.23.1.  
Eio types to know: `Eio.Promise.u` (resolver), `_ Eio.Time.clock`, `Eio_unix.Stdenv.base`.

## Local Kafka broker

Redpanda (native Linux, no Docker). Start: `rpk redpanda start --overprovisioned --smp 1 --memory 512M`  
Topics: `sun-demo`, `sun-producer-test`, `sun-consumer-test`  
Default broker address: `localhost:9092`

## Documentation Protocol

You must maintain and consult the project's source-of-truth markdown files:

1. **At Startup / Task Initialization**:
   - Explicitly read `docs/planning/ROADMAP.md` and `docs/planning/WORK_SUMMARY.md` using your file-reading tool before writing any code.
   - Align your execution path with the active milestone in `docs/planning/ROADMAP.md` and the current active tasks in `docs/planning/WORK_SUMMARY.md`.

2. **When Writing Code**:
   - Refer to `README.md` for foundational architecture rules.
   - Refer to the `*.md` spec file co-located with the package you are working in (e.g. `integrations/kafka/kafka-eio-producer/kafka-eio-producer.md`, `integrations/observability/obs-eio/obs-eio.md`) for feature implementation guidelines.

3. **At Task Completion / Session End**:
   - Update `docs/planning/WORK_SUMMARY.md` to accurately reflect what was accomplished, what is currently "In Progress", and any new implementation hurdles or blockers discovered.
   - If a major milestone is hit, update the status checklist in `docs/planning/ROADMAP.md`.
