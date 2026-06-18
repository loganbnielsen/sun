# Sun

Sun is a production platform for startups built around autonomous domain teams and typed event contracts. You write the business logic. Sun handles the infrastructure — Kafka, HTTP routing, scheduled functions, observability, and Kubernetes deployment — so a small team of engineers can ship and operate real production services without dedicated DevOps expertise.

---

## The Model

A company adopting Sun creates a **workspace** with three layers:

```
venus/
  events/                     ← event contracts, owned by the publishing team
    payments/
      charged.ml              ← ChargeEvent : Kafka_service.MESSAGE
      refunded.ml
    comms/
      notification_sent.ml
  app/                        ← service code, organized by domain team
    payments/                 ← payments team
      charge-svc/             ← REST API service
      fund-svc/               ← REST API service
      deposit-fn/             ← scheduled function (cron)
    comms/                    ← comms team
      broadcast-svc/          ← REST API service
      broadcast-worker/       ← Kafka consumer — imports events/payments/
      target-svc/             ← REST API service
  infra/                      ← global platform infrastructure
    cluster.tf
    kafka.tf
    observability.tf
    ingress.tf
  dune-project
```

**`events/<team>/`** — event contracts. The publishing team defines and owns these. Consumers import from here, never from the service that happens to produce the event.

**`app/<team>/<name>-svc`** — a REST API service. Defines routes and handlers.  
**`app/<team>/<name>-worker`** — a Kafka consumer. Processes event streams.  
**`app/<team>/<name>-fn`** — a scheduled function. Runs on a cron schedule.

**`infra/`** — global platform resources (cluster, networking, Kafka, observability). Team-level infrastructure (namespaces, Kafka ACLs, network policies, service accounts) is derived automatically by Sun from the `app/` structure.

Teams are autonomous at the domain level. They don't coordinate through shared code — they coordinate through **events**.

---

## Cross-Domain Communication

Services communicate by publishing typed Kafka events that other teams' workers subscribe to independently. The schema is the contract; nothing else is shared.

```
payments/charge-svc  →  publishes ChargeCompleted event
                                  ↓
comms/broadcast-worker  →  subscribes, sends push notification
financials/ledger-worker  →  subscribes, records the transaction
```

Each team consumes at their own pace with their own consumer group. Sun's schema registry integration enforces the contract at the wire level — a producer can't publish a message that breaks a registered schema.

---

## What Sun Handles

When you define a service in a Sun workspace, you get the full stack without writing infrastructure code:

- **Kafka** — topic provisioning, schema registration, Confluent wire format, producer and consumer lifecycle *(complete)*
- **HTTP** — REST routing, middleware, request/response types *(complete)*
- **Storage** — PostgreSQL via caqti, typed table functor, migrations *(complete)*
- **Observability** — structured logs to Loki, metrics to Prometheus, Grafana dashboards — wired automatically, no instrumentation code required *(complete)*
- **Deployment** — Kubernetes manifests, Terraform for cloud infrastructure, Argo CD for GitOps, CI workflow references *(complete)*

You focus on the handler. Sun handles the rest.

---

## Why OCaml

OCaml's type system catches entire classes of bugs at compile time that other languages discover in production. There is no null. Errors are values. Pattern matching is exhaustive. The compiler enforces your business logic's invariants.

OCaml 5 adds a first-class effects system that enables structured concurrency via **Eio** — lightweight fibers with backpressure, cancellation, and composable resource management. Sun's async model is built on this foundation.

The result: services that are fast, and whose failure modes are explicit and typed rather than implicit and surprising.

---

## AI-Agent-First Design

Sun is built with AI-assisted development as a first-class design constraint. Predictable conventions, strong types, and enforced structure mean an AI agent working in a Sun codebase produces accurate output and can't introduce an entire class of infrastructure bugs — because the framework's conventions make the wrong thing hard to express.

The intended workflow: an engineer describes what a service should do; an AI agent scaffolds and wires it; the type system catches what slips through. Sun is designed to make this loop fast and reliable from day one.

---

## Framework, Not Library

Sun crosses the line from library to framework along two axes.

**Code layer — Inversion of Control.** You don't write a `main` that calls Sun. Sun's functors (`Sun.Service.Make`, `Sun.Worker.Make`, `Sun.Fn.Make`) own the application lifecycle — Eio fiber loops, signal handling, telemetry wiring, graceful shutdown. You provide routes, schedules, and handlers. Sun runs them.

**Infrastructure layer — Infrastructure Synthesis.** Sun derives Kubernetes manifests, Kafka ACLs, and NetworkPolicies directly from the `app/` directory structure. Generated YAML is a build artifact, not a file you write or commit. Each service may optionally carry a `sun.toml` with high-level overrides (`[infra.scale]`, `[infra.kafka]`, `[infra.env]`, `[infra.deploy]`, `[infra.labels]`, `[infra.rollout]`); Sun merges those overrides into its synthesized manifests at deploy time. See `docs/deployment/escape-hatches.md` for the full reference.

The boundary: Sun behaves as a framework at the network and infrastructure boundaries. Inside those boundaries — storage clients, business logic, data modeling — it behaves as a library of typed primitives.

---

## Design Principles

**Errors are values.** Every operation that can fail returns a `Result`. No exceptions for control flow. The type system enforces that failure is handled.

**One way to do things.** Sun picks conventions and enforces them. Module structure, error handling, configuration, observability — these are not decisions each service makes independently. Deviation is explicit.

**Explicit over implicit.** No magic. No hidden control flow. If something happens, there is a function call you can find. This applies especially to security: auth is always declared explicitly on each route. Sun does not infer auth strategy from path conventions or other signals. The developer states intent; the framework enforces it.

**DevOps expertise, not engineering judgment.** Sun removes the need to know Terraform, Helm, or Kubernetes to ship a production service. It does not remove the need to make sound engineering decisions. Infrastructure, deployment, and observability are handled by the framework. Security design, data modeling, and business logic stay in the developer's hands and stay readable in the code.

**Security on Day 1.** Sun's framework types carry security configuration as a first-class concern — transport encryption, SASL authentication, and TLS are all part of the data model from the beginning, defaulting to plaintext only in dev and reading from environment variables in all other environments. You can't accidentally ship a production service with no security configuration because the type forces the field.

**Dev mirrors prod exactly.** `sun dev up` provisions a local k3d cluster with the same Helm charts used in production — Redpanda, PostgreSQL, Loki, Prometheus, Grafana. The only difference is scale (single replica, no persistent volume). Port-forwards make all services reachable at the same addresses your services expect. Surprises at deploy time are a symptom of divergent environments; Sun eliminates that divergence.

**FOSS infrastructure.** The full stack runs on open source primitives — Kubernetes, Strimzi, Argo CD, Prometheus, Loki, Grafana, Terraform. No vendor lock-in. Cloud providers are an infrastructure detail.

**Cloud-agnostic Kubernetes.** Sun services deploy to any Kubernetes cluster. The target is k8s, not a specific cloud provider. StorageClass abstraction, Strimzi for Kafka, and Terraform modules make the stack portable across AWS, GCP, Azure, or bare metal.

---

## Scaling Story

Sun is designed to carry a startup from their first deployed service to hundreds of thousands of users before infrastructure complexity would require rethinking the platform. The teams that outgrow Sun will do so because they have strict requirements at significant scale — not because Sun's architecture is limiting at the stage where most teams actually are.

---

## Status

Sun is under active development. The Kafka layer is the proof-of-concept — built using Sun's own conventions, with AI assistance, as validation that those conventions work.

See [docs/guides/TUTORIAL.md](docs/guides/TUTORIAL.md) for a full walkthrough of how Sun works, [docs/architecture/PRODUCT_ARCHITECTURE.md](docs/architecture/PRODUCT_ARCHITECTURE.md) for how the framework, user workspaces, and future hosting plane fit together, and [docs/planning/ROADMAP.md](docs/planning/ROADMAP.md) for the phased plan.

| Layer | Status |
|---|---|
| Kafka (core, producer, consumer, service) | Complete |
| Observability core (`obs-eio` — tracing, logging, metrics API) | Complete |
| Observability backends (Loki, Prometheus) | Complete |
| HTTP service layer (`-svc`) | Complete |
| Function layer (`-fn`, cron) | Complete |
| Worker layer (`-worker`, Kafka consumer) | Complete |
| Observability auto-wiring (`-svc`, `-fn`, `-worker`) | Complete |
| Storage (PostgreSQL) | Complete |
| Sun CLI — scaffold (`sun new workspace/svc/worker/fn/event`) | Complete |
| Sun CLI — local infra (`sun dev up/down/status/run`) | Complete |
| Sun CLI — deploy (`sun up`, `sun status`, `sun migrate`) | Complete |
| Sun CLI — secrets (`sun secret set/list/delete`) | Complete |
| Production deployment pipeline (`sun deploy`, Terraform, Argo CD) | Complete |
| Progressive delivery (`[infra.rollout]`, Argo Rollouts) | Complete |
| Sun-hosted executor (`sun cloud init/deploy/releases/logs`) | `sun cloud init` provisions AWS/GCP infrastructure; `sun cloud deploy` builds Docker images, pushes to `--registry`, and records release history; `sun cloud releases` and `sun cloud logs` surface that history |

---

## Quickstart

From zero to a running service with HTTP, Kafka, and PostgreSQL in under five minutes.

**Prerequisites:** k3d, Helm, Docker, kubectl, and the `sun` and `sundev` binaries on your PATH.

Install `sun` (Linux x86_64) — download the self-contained release bundle:

```bash
# Replace vX.Y.Z with the latest version from https://github.com/loganbnielsen/sun/releases
curl -L https://github.com/loganbnielsen/sun/releases/latest/download/sun-vX.Y.Z-linux-x86_64.tar.gz \
  | tar xz
export PATH="$PWD/sun-vX.Y.Z-linux-x86_64/bin:$PATH"   # add to ~/.bashrc or ~/.zshrc
```

The tarball includes the `sun` binary and the framework source trees (`framework/` and `integrations/`). No `SUN_HOME` or separate clone required — `sun new workspace` resolves the framework source automatically from the bundle layout.

**Contributors / building from source:** Clone the repo and set `SUN_HOME` instead:

```bash
git clone https://github.com/loganbnielsen/sun.git ~/sun
export SUN_HOME=~/sun   # add to ~/.bashrc or ~/.zshrc
```

`sundev` (internal pipeline/worktree tooling) is build-from-source only — see [Requirements](#requirements).

```bash
# 1. Provision the local cluster (Redpanda, PostgreSQL, Loki, Prometheus, Grafana)
sun dev up

# 1a. (Optional) Iterate fast on code changes — runs services as native binaries, no Docker rebuild
sun dev run

# 2. Scaffold a new workspace
sun new workspace pluto
cd pluto

# 3. Build images and deploy to the cluster (final smoke test)
sun up

# 4. Run database migrations
sun migrate

# 5. See what's running
sun status

# 6. Roll back if something goes wrong
sun rollback                   # roll back all services
sun rollback payments/charge_svc  # roll back one service
```

`sun up` starts port-forwards automatically. `sun status` shows the live URL:

```
Namespace: pluto-comms
NAME                              READY   STATUS    RESTARTS   AGE
notify-worker-77859bbfff-77vm6    1/1     Running   0          2m

Namespace: pluto-payments
NAME                           READY   STATUS    RESTARTS   AGE
charge-svc-5464d77bd4-2lnb9    1/1     Running   0          2m
  →  http://localhost:8080  (charge-svc)
```

```bash
# 7. Try it
curl localhost:8080/health
# ok

curl -X POST localhost:8080/charges \
  -H 'Content-Type: application/json' \
  -d '{"customer_id":"cus_123","amount_cents":4999,"currency":"usd"}'
# {"id":"ch_042381","accepted":true}

curl localhost:8080/notifications
# [{"charge_id":"ch_042381","customer_id":"cus_123","amount_cents":4999,"currency":"usd"}]
```

```bash
# 8. View logs and metrics in Grafana
open http://localhost:3000   # admin / admin
```

In Grafana Explore, query `{service=~"pluto-.*"} | logfmt` to see structured logs from both the charge service and the notify worker, with trace IDs linking HTTP spans to Kafka consumer spans.

### What the scaffold generates

`sun new workspace pluto` produces a fully-wired multi-service workspace:

| Path | Description |
|------|-------------|
| `events/payments/charged.ml` | Typed `Charged` Kafka event contract |
| `app/payments/charge_svc/` | HTTP service: `POST /charges`, `GET /notifications`, `GET /health` |
| `app/comms/notify_worker/` | Kafka worker: consumes `Charged`, writes to DB |
| `lib/notification.ml` | Shared `Notification` storage module (used by svc + worker) |
| `db/migrations/0001_notifications.sql` | Initial schema |
| `Dockerfile` (×2) | Container images for each service |
| `.github/workflows/sun-ci.yml` | CI workflow: build/test, build images, deploy via GitOps |

The service writes charges to PostgreSQL on `POST /charges` and reads them back on `GET /notifications`. The worker subscribes to the `charged` Kafka topic and logs each event with full observability context. Both services ship metrics to Prometheus and logs to Loki automatically — no instrumentation code required.

### Adding a new domain

```bash
# Add a new event type
sun new event billing/payment_confirmed

# Add a worker that consumes it
sun new worker logistics/fulfillment

# Add a scheduled function
sun new fn billing/invoice

# Redeploy
sun up
```

Each command generates files that compile immediately and integrate with the existing observability and deployment stack.

### Shipping a Change

```bash
# Build, push, and deploy updated images
sun up

# Check pod health after deploy
sun status

# Something went wrong? Roll back to the previous revision
sun rollback                        # all services in the workspace
sun rollback payments/charge_svc    # one service only
```

`sun rollback` rolls back each matching service and waits for the previous
revision to become healthy before reporting success. The namespace and
deployment names are derived from the workspace and service path using the
same conventions as `sun up` and `sun deploy`, so no extra flags are needed.

For services using a standard `Deployment` (no `[infra.rollout]` in `sun.toml`),
`sun rollback` calls `kubectl rollout undo deployment/<name>`. For services
configured with `[infra.rollout]` (Argo Rollouts), it automatically calls
`kubectl argo rollouts undo <name>` instead — this requires the
[Argo Rollouts kubectl plugin](https://argoproj.github.io/argo-rollouts/installation/#kubectl-plugin)
to be installed. If the plugin is not found, `sun rollback` prints an actionable
error with the manual command and exits 1.

---

## Day-2 Operations

### Streaming logs

```bash
# Stream logs from a service (follows by default)
sun logs payments/charge_svc

# Bare name works when unambiguous across domains
sun logs charge_svc

# Snapshot — last 200 lines, no follow
sun logs payments/charge_svc --no-follow --tail=200

# Only new lines, no history
sun logs payments/charge_svc --tail=0
```

`sun logs` resolves `<workspace>-<domain>` as the Kubernetes namespace automatically, so you never need to remember Sun's naming convention. Underscores in service names are mapped to hyphens (Kubernetes convention).

Before streaming, `sun logs` prints a copyable Grafana Explore URL with a pre-built LogQL query for that service. Open the URL to see Loki-routed application logs, trace IDs, and span details. Pass `--grafana-base-url` if your Grafana is not at `http://localhost:3000`:

```bash
sun logs payments/charge_svc --grafana-base-url http://grafana.internal:3000
```

**Note:** `sun logs` streams stdout/stderr from the container pod. Application-level logs (emitted via `Obs.log_t`) are routed to Loki and appear in Grafana, not in the kubectl stream. Use the Grafana URL printed by `sun logs` to query Loki-routed logs for the same service.

For historical log search — spanning multiple services, time ranges, or correlated by trace ID — open Grafana at http://localhost:3000 and use the Explore view with Loki as the data source. Query `{service=~"pluto-.*"} | logfmt` to search across all services in a workspace.

### Checking pod health

```bash
sun status                 # all domains
sun status payments        # single domain
```

### Database migrations

```bash
sun migrate                # apply pending migrations
sun migrate status         # show applied / pending
sun migrate rollback       # roll back the last applied migration
```

### Secrets

```bash
# Create or update an environment-scoped secret
sun secret set DATABASE_URL --env production --value "$DATABASE_URL"

# List keys only; values are never printed
sun secret list --env production

# Delete a key
sun secret delete DATABASE_URL --env production
```

Local and customer-cloud environments materialize secrets as Kubernetes
`Secret` objects. Hosted mode has a typed client boundary, but no production
control-plane endpoint yet.

**Note:** `sun secret set` updates the Kubernetes Secret immediately, but running pods are not automatically restarted. The new value takes effect the next time the pod restarts (after `sun up`, `sun deploy`, or a manual `kubectl rollout restart`).

---

## Deployment Modes

Sun supports three deployment modes, covering local development through production.

### Local — `sun up`

Builds Docker images and deploys to the local k3d cluster provisioned by `sun dev up`. For development and smoke-testing only.

```bash
sun up              # build + deploy all services in the current workspace
sun up --dry-run    # print generated YAML to stdout without applying
```

### Customer-cloud direct — `sun deploy`

CI builds and pushes images to a production registry; `sun deploy` synthesizes manifests and applies them to a customer-managed Kubernetes cluster. Run after the Docker build step in CI.

```bash
sun deploy --image-tag $SHA --registry $REGISTRY
sun deploy --image-tag $SHA --registry $REGISTRY --dry-run  # diff review in PRs
```

### Customer-cloud GitOps — `sun deploy --emit-to`

`sun deploy --emit-to <dir>` writes synthesized manifests to a directory instead of applying them. CI commits that directory to a separate GitOps repo; Argo CD reconciles the cluster automatically.

```bash
sun deploy --emit-to manifests/ --image-tag $SHA --registry $REGISTRY
# CI commits manifests/ to the GitOps repo; Argo CD applies the change
```

> **Security:** By default, the generated YAML includes redacted `Secret` placeholders — values are replaced with `REDACTED` so the file is safe to inspect but not usable as-is. To emit `ExternalSecret` CRDs for the External Secrets Operator instead (production-ready GitOps), pass `--secret-backend external-secrets`:
>
> ```bash
> sun deploy --emit-to manifests/ --image-tag $SHA --registry $REGISTRY \
>   --secret-backend external-secrets \
>   --secret-store-ref my-cluster-store
> ```
>
> The `--secret-store-ref` flag names the `ClusterSecretStore` (or `SecretStore` with `--secret-store-kind SecretStore`) that ESO will use to resolve secret values at runtime. See the External Secrets Operator docs for store setup.

### Plan inspection — `sun deploy --emit-plan-to`

Writes the deployment plan as JSON for external tooling or debugging. The schema is experimental.

```bash
sun deploy --emit-plan-to plan.json --image-tag $SHA
```

### `sun.toml` — per-service overrides

Each service may carry a `sun.toml` with high-level overrides. All sections are optional.

```toml
[infra.scale]
replicas = 2
cpu      = "500m"
memory   = "512Mi"

[infra.env]
config = { LOG_LEVEL = "debug" }    # extra ConfigMap entries
secrets = ["DATABASE_URL", "API_TOKEN"]

[infra.deploy]
rollout_strategy = "Recreate"       # or "RollingUpdate" (default)
ingress_host     = "api.example.com"
ingress_path     = "/v1"

[infra.labels]
extra_labels = { team = "payments" }

[infra.rollout]
strategy = "canary"
steps = [{weight = 10}, {pause = {duration = 300}}, {weight = 50}, {pause = {}}, {weight = 100}]
```

`[infra.rollout]` renders Argo Rollouts resources instead of standard
Deployments when configured. Canary and blue-green strategies are supported.
See `docs/deployment/escape-hatches.md` for the complete field reference and the
four-level escape-hatch hierarchy.

---

## Cloud Infrastructure — `sun cloud`

The `sun cloud` group of subcommands provisions infrastructure and manages hosted releases.

| Command | Description |
|---------|-------------|
| `sun cloud init --aws\|--gcp [--var-file FILE] [--dry-run]` | Provision cloud infrastructure via Terraform |
| `sun cloud deploy [--environment ENV] [--registry URL]` | Build, push, and record a hosted release |
| `sun cloud releases [--page N]` | List recent hosted releases |
| `sun cloud logs --release ID` | Stream the deploy log for a release |

### `sun cloud init` — provision cloud infrastructure

`sun cloud init` provisions production-grade cloud infrastructure using the Terraform modules in `platform/infra/aws/` and `platform/infra/gcp/`. It runs `terraform init` followed by `terraform apply -auto-approve` and prints the provisioned endpoints on completion.

### Prerequisites

- **`terraform` CLI** — [https://developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install)
- **Cloud credentials in the environment:**
  - AWS: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` (or an active AWS profile)
  - GCP: `GOOGLE_APPLICATION_CREDENTIALS` pointing to a service-account key file, or `gcloud auth application-default login`
- **Terraform modules** — the release tarball bundles `platform/infra/` inside the extracted directory. If you are using a source checkout instead of the tarball, set `SUN_HOME` to the repo root:
  ```bash
  export SUN_HOME=/path/to/sun
  ```
  This is only needed for source checkouts; the tarball bundle resolves modules automatically.

### Usage

```bash
# Provision AWS infrastructure (EKS, ECR, RDS, Route53)
sun cloud init --aws

# Provision GCP infrastructure (GKE, Artifact Registry, Cloud SQL)
sun cloud init --gcp

# Dry-run: show terraform plan without creating resources
sun cloud init --aws --dry-run
sun cloud init --gcp --dry-run

# Pass a Terraform variables file
sun cloud init --aws --var-file prod.tfvars
```

On success the command prints the key provisioned endpoints, for example:

```
  cluster_name                  sun-prod
  cluster_endpoint              https://ABCDEF123456.gr7.us-east-1.eks.amazonaws.com
  kubeconfig_command            aws eks update-kubeconfig --region us-east-1 --name sun-prod
  ecr_registry                  123456789.dkr.ecr.us-east-1.amazonaws.com
  ecr_login_command             aws ecr get-login-password ...
```

Sensitive outputs (database passwords, connection strings) are never printed; retrieve them with `terraform output -raw <name>` if needed.

### `sun cloud deploy` — build and record a hosted release

```bash
# Build images, push to a registry, and record a release
sun cloud deploy --environment production --registry ghcr.io/your-org

# Dry-run: print project/env/tag without building or recording
sun cloud deploy --environment staging --registry ghcr.io/your-org --dry-run
```

`CLOUD_REGISTRY` may be set in the environment instead of passing `--registry` on every invocation.

### `sun cloud releases` — list recent releases

```bash
sun cloud releases          # page 1 (default page size: 20)
sun cloud releases --page 2
```

### `sun cloud logs` — stream a release's deploy log

```bash
sun cloud logs --release rel-myworkspace-1718200000000
```

---

## Project Structure

```
sun/
  cli/
    sun/                  # customer CLI: sun new / dev / up / deploy / migrate
    sundev/               # internal repo workflow and ticket pipeline tooling
  framework/
    sun-svc/              # REST routing, auth, graceful shutdown, metrics
    sun-worker/           # Kafka consumer, schema registration, metrics
    sun-fn/               # scheduled function, Pushgateway metrics push
  integrations/kafka/
    kafka-eio-core/       # shared FFI bindings and error types
    kafka-eio-producer/   # Eio-native Kafka producer
    kafka-eio-consumer/   # Eio-native Kafka consumer
    kafka-eio-service/    # high-level typed message + schema layer
  integrations/observability/
    obs-eio/              # core tracing, logging, metrics API
    obs-eio-loki/         # Loki push backend
    obs-eio-prometheus/   # Prometheus exposition backend
  integrations/storage/
    sun-storage/          # PostgreSQL pool, typed queries, migrations, Table.Make functor
  platform/
    deploy/               # local infra scripts, Dockerfile, k8s manifests, schemas
    infra/                # Terraform, Argo CD, CI deployment references
  examples/venus/         # reference workspace — two teams, typed events, storage
    events/payments/      # Charged event contract (owned by payments team)
    app/comms/            # notify-worker (comms team, consumes Charged)
    db/migrations/        # notifications table
    bin/run.ml            # orchestration runner
  examples/local-demo/          # legacy single-team demo
  docs/                   # architecture, guides, planning, audit checklists
    architecture/contributing-map.md  # contributor ownership and extension map
  project/
    audits/               # dated audit outputs
    test/                 # hooks and performance baselines
    tickets/              # internal work tracking
  dune-workspace          # unified build root
```

Each package is independently usable. A worker that only needs Kafka does not pull in the HTTP layer.

---

## Requirements

**Runtime (binary install):**

- `librdkafka-dev`, `libpq-dev`, `libpq5` (`sudo apt-get install -y librdkafka-dev libpq-dev libpq5`)
- Redpanda (native Linux): `rpk redpanda start --overprovisioned --smp 1 --memory 512M`

**Build from source (contributors):**

- OCaml 5.4.1, Eio 1.3, dune 3.23.1 (install via opam)
- All runtime deps above

```bash
# Install sundev and build everything
eval $(opam env)
dune build
ln -sf "$(pwd)/_build/default/cli/sun/bin/main.exe" ~/.local/bin/sun
ln -sf "$(pwd)/_build/default/tools/sundev/bin/main.exe" ~/.local/bin/sundev
```

## Test

```bash
# Unit tests (no broker needed)
dune test integrations/kafka/kafka-eio-core/test/ integrations/observability/obs-eio/test/

# Full integration tests (requires Redpanda + Loki)
bash platform/local/scripts/ensure-broker.sh
bash platform/local/scripts/ensure-loki.sh
KAFKA_BROKERS=localhost:9092 LOKI_URL=http://localhost:3100 dune test
```
