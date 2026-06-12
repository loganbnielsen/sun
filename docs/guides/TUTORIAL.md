# Sun Tutorial

This tutorial walks through building and running a real multi-service application on Sun. By the end you will have two services deployed to a local Kubernetes cluster, talking to each other through Kafka, persisting data in PostgreSQL, and emitting structured logs and metrics visible in Grafana — without writing a single Kubernetes manifest or Helm chart.

---

## What Sun is

Sun is a production platform for OCaml services. It gives you three service primitives:

- **`-svc`** — a long-running HTTP service with routes, auth, and a `/healthz` endpoint
- **`-worker`** — a Kafka consumer that processes a typed event stream
- **`-fn`** — a scheduled function that runs on a cron expression

These primitives share a common observability layer (Loki for logs, Prometheus for metrics) and a storage layer (PostgreSQL). Sun wires all of it together at startup. You write the handler; Sun runs it.

The `sun` CLI scaffolds new services, manages the local development cluster, builds and deploys container images, and runs database migrations.

---

## Prerequisites

- k3d v5+ and Helm v3+
- Docker, kubectl
- `librdkafka-dev`, `libpq-dev`, `libpq5` (`sudo apt-get install -y librdkafka-dev libpq-dev libpq5`)

Install `sun` (Linux x86_64) — download the self-contained release bundle:

```bash
# Replace vX.Y.Z with the latest version from https://github.com/loganbnielsen/sun/releases
curl -L https://github.com/loganbnielsen/sun/releases/latest/download/sun-vX.Y.Z-linux-x86_64.tar.gz \
  | tar xz
export PATH="$PWD/sun-vX.Y.Z-linux-x86_64/bin:$PATH"   # add to ~/.bashrc or ~/.zshrc
```

The tarball includes the `sun` binary and the framework source trees (`framework/` and `integrations/`). No `SUN_HOME` or separate clone required — `sun new workspace` resolves the framework source automatically from the bundle layout.

> **Build from source:** Contributors who need `sundev` or want to modify the framework should clone the repo and build:
> ```bash
> git clone https://github.com/loganbnielsen/sun.git ~/sun
> export SUN_HOME=~/sun   # add to ~/.bashrc or ~/.zshrc
> eval $(opam env)  # requires OCaml 5.4.1 + opam
> dune build cli/
> ln -sf "$(pwd)/_build/default/cli/sun/bin/main.exe" ~/.local/bin/sun
> ln -sf "$(pwd)/_build/default/tools/sundev/bin/main.exe" ~/.local/bin/sundev
> ```

---

## Part 1 — Local infrastructure

Sun's local cluster mirrors production exactly: same Helm charts, same service DNS names, same security model. The only difference is scale (single replica, no persistent volumes).

```bash
sun dev up
```

This creates a k3d cluster named `sun-local` and installs:

| Component | What it does |
|-----------|-------------|
| Redpanda | Kafka-compatible broker + schema registry |
| PostgreSQL | Primary database |
| Loki + Grafana | Log aggregation and dashboards |
| Prometheus + Pushgateway | Metrics collection |

When it finishes, every component is reachable on localhost:

```
Kafka           localhost:9092
Schema registry localhost:8081
PostgreSQL      localhost:5432
Loki            localhost:3100
Grafana         localhost:3000   (admin / admin)
Prometheus      localhost:9090
```

These port-forwards are managed by Sun in the background (PIDs recorded in `~/.local/share/sun/`). `sun dev down` tears everything down. Running `sun dev up` again clears any stale port-forwards first, so repeat runs are safe.

---

## Part 2 — Scaffold a workspace

A **workspace** is a directory that contains one or more domain teams, each with their own services. Teams communicate through typed Kafka events — never through shared code.

```bash
sun new workspace pluto
cd pluto
```

> **Vendor links:** `sun new workspace` creates `vendor/framework` and `vendor/integrations` as symlinks into the Sun source tree. These links are how the generated workspace finds Sun's library source at build time — `dune build` will fail with "Library not found: sun_svc" if they are missing.
>
> When using the **release tarball** (the install path above), the framework source is bundled inside the extracted directory. `sun new workspace` finds it automatically — no `SUN_HOME` needed.
>
> When using a **source checkout**, set `SUN_HOME` before running `sun new workspace`:
>
> ```bash
> export SUN_HOME=~/sun   # set once in ~/.bashrc or ~/.zshrc
> ```
>
> The CLI uses `SUN_HOME` to locate the framework and create the vendor symlinks automatically.

This generates 22 files. Here is what was created and why:

```
pluto/
  dune-project                    ← root dune project (required)
  .ocamlformat                    ← OCaml formatter config
  README.md                       ← workspace-level docs

  .github/workflows/
    deploy.yml                    ← CI deploy workflow
    sun-ci.yml                    ← Full Sun CI pipeline

  events/payments/
    charged.ml                    ← the Charged event contract
    dune

  app/payments/charge_svc/
    lib/handler.ml                ← HTTP route handlers
    lib/dune
    bin/main.ml                   ← service entrypoint
    bin/dune
    Dockerfile
    sun.toml

  app/comms/notify_worker/
    lib/notify_worker.ml          ← Kafka message handler
    lib/dune
    bin/main.ml                   ← worker entrypoint
    bin/dune
    Dockerfile
    sun.toml

  lib/
    notification.ml               ← shared DB module (used by svc and worker)
    dune                          ← pluto_storage library

  db/migrations/
    0001_notifications.sql        ← initial schema
```

Two domain teams are wired together out of the box:

- **payments team** — owns the `Charged` event and runs `charge_svc`
- **comms team** — runs `notify_worker`, which consumes `Charged` events published by the payments team

### The event contract

`events/payments/charged.ml` defines the Kafka event schema as an OCaml module:

```ocaml
type t = {
  id          : string;
  customer_id : string;
  amount_cents: int;
  currency    : string;
}

let topic  = "pluto-payments-charges"
let schema = {|{"type":"record","name":"Charged",...}|}
```

The `topic` and `schema` fields satisfy the `Kafka_service.MESSAGE` module type. Sun registers the Avro schema with the schema registry at worker startup. A producer cannot publish a message that breaks the registered schema.

### The HTTP service

`app/payments/charge_svc/lib/handler.ml` defines routes:

```ocaml
let routes pool = [
  Route.get  "/health"        ~auth:`Public (fun _req -> Response.ok "ok");
  Route.post "/charges"       ~auth:`Public (fun req -> ...);
  Route.get  "/notifications" ~auth:`Public (fun _req -> ...);
]
```

`POST /charges` generates a charge ID, writes it to PostgreSQL via `Notification.insert`, and returns `{"id":"ch_XXXXXX","accepted":true}`. `GET /notifications` reads the last 20 rows back.

Auth is always declared explicitly on each route. There is no implicit auth based on path conventions.

### The worker

`app/comms/notify_worker/lib/notify_worker.ml` is a Kafka consumer:

```ocaml
module Make (Config : sig
  val pool : Db.pool option
  val ot   : Obs.t
end) = struct
  module Message = Charged
  let group_id = "pluto-comms-notify-worker"

  let handle (msg : Message.t) ~ack ~trace_ctx:_ =
    Obs.log_t Config.ot Obs.Info
      ~fields:[("charge_id", msg.id); ("customer_id", msg.customer_id)]
      "charge event received";
    (match Config.pool with
     | Some pool -> ignore (Notification.insert pool ...)
     | None -> ());
    ack ();
    Ok ()
end
```

`module Message = Charged` tells Sun which Kafka topic and schema this worker consumes. `group_id` is the Kafka consumer group name. `handle` is called once per message with the decoded payload.

The `Make(Config)` functor pattern lets you inject the database pool and observability handle without module-level mutable state. Sun's worker runtime (`Worker.Make(W).run`) manages the Kafka connection lifecycle, graceful shutdown, and per-message metrics.

### The shared storage module

`lib/notification.ml` is used by both the svc and the worker. It wraps two caqti queries:

```ocaml
let insert pool ~charge_id ~customer_id ~amount_cents ~currency = ...
let list_recent pool = ...
```

Both return `(_, Storage_error.t) result`. No exceptions cross module boundaries.

The `lib/dune` file publishes this as `pluto_storage`, a library both services depend on.

---

## Part 3 — Deploy to the local cluster

```bash
sun up
```

For each service that has a `Dockerfile`, Sun:

1. Builds the Docker image and tags it with the short git SHA
2. Pushes it to the local registry (`sun-registry:5000`)
3. Generates Kubernetes manifests (Namespace, Deployment, Service, ServiceAccount, ConfigMap)
4. Validates them against the live API server (`kubectl apply --dry-run=server`)
5. Applies them live

The generated ConfigMap injects cluster-internal service addresses so pods communicate via k8s DNS, not localhost port-forwards:

```
KAFKA_BROKERS       redpanda.redpanda.svc.cluster.local:9093
SCHEMA_REGISTRY_URL http://redpanda.redpanda.svc.cluster.local:8081
POSTGRES_URL        postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev
LOKI_URL            http://loki.monitoring.svc.cluster.local:3100
```

These names are deterministic from the Helm release names chosen by `sun dev up`.

After `sun up` finishes, check what's running:

```bash
sun status
```

```
Namespace: pluto-comms
NAME                              READY   STATUS    RESTARTS   AGE
notify-worker-77859bbfff-77vm6    1/1     Running   0          2m

Namespace: pluto-payments
NAME                           READY   STATUS    RESTARTS   AGE
charge-svc-5464d77bd4-2lnb9    1/1     Running   0          2m
  →  http://localhost:8080  (charge-svc)
```

---

## Part 4 — Run database migrations

```bash
sun migrate
```

If `POSTGRES_URL` is not set, Sun detects the cluster postgres automatically and starts a background port-forward:

```
Forwarding postgresql (cluster) → localhost:15432 ...
Applying migrations from db/migrations...
Done.
```

The migration runner applies SQL files in numeric order and records each applied version in a `sun_<workspace>_schema_migrations` table (for example, `sun_pluto_schema_migrations` when your workspace directory is `pluto`). Re-running `sun migrate` is safe — already-applied versions are skipped.

The table name is derived from your workspace directory name. Use `--table <name>` to override the default if you need a custom tracking table.

Check migration status at any time:

```bash
sun migrate status
```

```
VER     NAME                            APPLIED AT
------------------------------------------------------------
1       0001_notifications              2026-06-05T12:34:56Z
```

---

## Part 5 — Try the API

`sun up` started the port-forward automatically — the service is already reachable at http://localhost:8080. If the port-forward was stopped, run `sun up` again to restart it (or run `kubectl port-forward svc/charge-svc -n pluto-payments 8080:80` directly).

```bash
# Health check
curl localhost:8080/health
# ok

# Create a charge
curl -X POST localhost:8080/charges \
  -H 'Content-Type: application/json' \
  -d '{"customer_id":"cus_123","amount_cents":4999,"currency":"usd"}'
# {"id":"ch_042381","accepted":true}

# List stored notifications
curl localhost:8080/notifications
# [{"charge_id":"ch_042381","customer_id":"cus_123","amount_cents":4999,"currency":"usd"}]
```

---

## Part 6 — Observe logs and metrics

Open Grafana at `http://localhost:3000` (admin / admin).

### Logs

Go to **Explore → Loki** and query:

```
{service=~"pluto-.*"} | logfmt
```

You will see structured log lines from both services. Each line includes `level`, `msg`, `span`, and any fields the handler added. W3C `traceparent` headers propagate across the Kafka boundary, so a charge request's trace ID appears in both the `charge-svc` logs and the `notify-worker` logs when the event is consumed.

### Metrics

Go to **Explore → Prometheus** and query:

```
sun_svc_requests_total
sun_worker_messages_total
sun_svc_request_duration_seconds_bucket
```

Sun registers these metrics automatically when `?ot` is wired in the service entrypoint. No instrumentation code is needed in the handler.

---

## Part 7 — Extend the workspace

Adding a new domain or service follows the same pattern.

### New event type

```bash
sun new event billing/payment_confirmed
```

Generates `events/billing/payment_confirmed.ml` with a stub `type t` and `schema`. Edit the type to match your payload; the compiler will find every place that needs updating.

**Schema backward compatibility:** Changing the `schema` field (the JSON Schema string) may break consumers that are still running against the old schema. The OCaml compiler catches structural type mismatches, but JSON schema changes are only caught at runtime when the worker calls `Kafka_service.register`. To catch breaking schema changes in CI before deploy, run the generated schema compatibility test:

```bash
SCHEMA_REGISTRY_URL=http://localhost:8081 dune test test/
```

`test/test_schemas.ml` (generated by `sun new workspace`) calls `Kafka_service.Schema.check_all` against the schema registry. If the new schema is incompatible with the already-registered version, the test fails and the schema change is blocked before it reaches staging. If `SCHEMA_REGISTRY_URL` is not set, the test skips safely — it is a no-op in unit CI.

### New worker

```bash
sun new worker logistics/fulfillment
```

Generates a minimal worker in `app/logistics/fulfillment_worker/`. Wire the event library into its `dune` file, set `module Message = Payment_confirmed`, implement `handle`, then redeploy:

```bash
sun up
```

### New service

```bash
sun new svc ops/admin
```

Generates `app/ops/admin_svc/` with a stub handler. Add routes and redeploy.

### New scheduled function

```bash
sun new fn billing/invoice
```

Generates `app/billing/invoice_fn/` with a `schedule` field (default `"0 * * * *"`) and a `run` function. Sun reads the schedule literal from source and generates a Kubernetes `CronJob`.

---

## How observability wiring works

Every service entrypoint follows the same pattern. Here is the charge-svc `bin/main.ml`:

```ocaml
let loki_url = Sys.getenv_opt "LOKI_URL" in
Eio_main.run @@ fun env ->
let log_backend = match loki_url with
  | None     -> Obs.stdout
  | Some url -> Obs_loki.create ~net:env#net ~clock:env#clock ~url
                  ~label_names:["service"; "team"] ()
in
let prom, render = Obs_prometheus.create () in
let ot = Obs.with_context
  (Obs.create ~service:"pluto-charge-svc" ~mono_clock:env#mono_clock
     ~backend:(Obs.compose log_backend prom))
  [("team", "payments")] in
```

`Obs.compose` fans out to both Loki and Prometheus from a single `Obs.t` handle. `Obs.with_context` binds ambient labels (`team = payments`) that appear on every log line and metric from this handle — without passing them explicitly to every call.

When `LOKI_URL` is absent (local `dune exec` dev), logs go to stdout in logfmt format. In the cluster, they go to Loki. The code is identical either way.

---

## CLI reference

```
sun new workspace <name>                          scaffold a new workspace
sun new svc <domain>/<name>                       add an HTTP service
sun new worker <domain>/<name>                    add a Kafka consumer
sun new fn <domain>/<name>                        add a scheduled function
sun new event <team>/<name>                       add a typed Kafka event

sun dev up                                        provision local k3d cluster
sun dev down                                      tear down the cluster
sun dev status                                    show running infra endpoints

sun up [path] [--dry-run] [--tag]                 build images and deploy to local cluster
sun deploy [--image-tag TAG] [--registry URL]     deploy pre-built images (CI mode)
sun deploy --emit-to DIR [--image-tag TAG] ...    write YAML for Argo CD (GitOps mode)
sun status [domain]                               show running pods and port-forward hints

sun migrate [apply]                               apply pending migrations
sun migrate status                                show per-file applied/pending table
sun migrate rollback                              roll back the last applied migration

sun rollback [domain/service]                     roll back last deploy for one or all services
sun logs <service> [--no-follow] [--tail=N]       stream logs from a deployed service

sun secret set <KEY> --env <ENV> --value <VAL>    create or update a secret
sun secret list --env <ENV>                       list secret keys (values never printed)
sun secret delete <KEY> --env <ENV>               delete a secret
```

---

## Part 8 — Production deployment

The `sun deploy` command is `sun up` without the build step. It is designed to run in CI after images have already been built and pushed to a production registry.

### Direct deploy (CI pushes to the cluster)

```bash
# In CI, after docker build && docker push:
sun deploy \
  --image-tag "$GIT_SHA" \
  --registry  "123456789.dkr.ecr.us-east-1.amazonaws.com"
```

Sun generates the same Kubernetes manifests as `sun up` but uses the provided registry and tag for the image reference. The cluster must be reachable (kubeconfig active).

### GitOps deploy (Argo CD watches a manifest repo)

```bash
# In CI:
sun deploy \
  --emit-to   manifests/ \
  --image-tag "$GIT_SHA" \
  --registry  "123456789.dkr.ecr.us-east-1.amazonaws.com"
# → writes manifests/pluto-payments-charge-svc.yaml, manifests/pluto-comms-notify-worker.yaml
# → CI commits and pushes these to the GitOps repo
# → Argo CD detects the change and applies it
```

The generated files contain the full manifest (Namespace, ServiceAccount, ConfigMap, Deployment/Service). If a service enables progressive delivery in `sun.toml`, Sun emits an Argo Rollouts `Rollout` instead of a Kubernetes `Deployment`. Argo CD applies these manifests with `ServerSideApply=true` and prunes resources that are removed.

### Day-2 operations

If a deploy introduces a regression, `sun rollback [domain/service]` runs `kubectl rollout undo` for one or all services and waits for the previous revision to become healthy — no kubectl knowledge required.

To inspect what a running service is doing, `sun logs <service>` streams live output directly from the cluster pod, following Sun's namespace convention automatically.

### Progressive delivery with Argo Rollouts

Services can opt into a typed high-level rollout strategy:

```toml
[infra.rollout]
strategy = "canary"
steps = [{weight = 10}, {pause = {duration = 300}}, {weight = 50}, {pause = {}}, {weight = 100}]
```

Canary steps are weight percentages from 0 to 100. For blue-green deployments, use:

```toml
[infra.rollout]
strategy = "blue-green"
```

Blue-green emits active and preview `Service` resources and disables automatic promotion. This is not a raw Argo YAML escape hatch: Sun supports only the fields above, and arbitrary Argo Rollouts features such as analysis templates and traffic-manager integrations are deferred.

See `platform/infra/ci/` for complete GitHub Actions workflow examples for both modes.

### Provisioning a production cluster

**AWS (EKS):**

```bash
cd platform/infra/aws
terraform init
terraform apply \
  -var="cluster_name=acme-prod" \
  -var="base_domain=acme.com" \
  -var="db_password=<secret>"

# → prints kubeconfig_command, ecr_registry, postgres_url
aws eks update-kubeconfig --region us-east-1 --name acme-prod
```

**GCP (GKE Autopilot):**

```bash
cd platform/infra/gcp
terraform init
terraform apply \
  -var="project_id=my-project" \
  -var="cluster_name=acme-prod" \
  -var="base_domain=acme.com" \
  -var="db_password=<secret>"

# → prints kubeconfig_command, artifact_registry, postgres_url
gcloud container clusters get-credentials acme-prod --region us-central1
```

**Install platform components** (Argo CD, Redpanda, Loki, Prometheus, cert-manager):

```bash
cd platform/infra/base
terraform init
terraform apply \
  -var="base_domain=acme.com" \
  -var="letsencrypt_email=ops@acme.com" \
  -var="install_postgresql=false"   # using RDS or Cloud SQL
```

After `terraform apply`, the cluster is identical to `sun dev up` — same DNS names, same ConfigMap values, same Grafana dashboards.

**Set up Argo CD GitOps** (one-time per cluster):

```bash
# Edit platform/infra/argocd/application.yaml — set GITOPS_REPO_URL and WORKSPACE_NAME
kubectl apply -f platform/infra/argocd/application.yaml
```

From this point, every `git push` to `main` in CI runs `sun deploy --emit-to`, commits the YAML to the GitOps repo, and Argo CD reconciles the cluster automatically.

### Hosted control-plane release history

`sun cloud deploy`, `sun cloud releases`, and `sun cloud logs` record release history in an in-memory store by default (state is lost when the process exits). To persist release history across restarts, set `CONTROL_PLANE_DATABASE_URL` to a Postgres connection URL:

```bash
export CONTROL_PLANE_DATABASE_URL=postgresql://user:pass@host:5432/dbname
sun cloud deploy --environment production
sun cloud releases
```

When `CONTROL_PLANE_DATABASE_URL` is unset (the default), the commands use in-memory state, which is convenient for local testing without requiring a database.
