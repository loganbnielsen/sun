# Observability Design

Sun treats observability as a workspace-level capability, not a per-service
add-on. A Sun workspace belongs to one company/product; domains (team-owned
verticals, e.g. `payments`, `comms`) inside it own the services, workers, and
functions that emit into the same observability surface.

The product rule is:

```text
one workspace -> one logs backend, one metrics backend, one dashboard surface
```

Individual domains and services are scoped views inside that surface,
selected by stable labels — the same convention `sun status`/`sun logs`
already use (`<domain>` or `<domain>/<service>`). A service can and should
have its own dashboard; it should not have its own isolated observability
stack.

> Earlier drafts of this doc introduced a `project` layer above `domain`
> (grouping multiple products/apps inside one workspace). Dropped: Sun's
> existing `domain` concept already means "team-owned vertical composed of
> services/workers/functions" (see `CLAUDE.md`'s "Teams own domains"), which
> is what `project` was actually describing. No new layer — `workspace ->
> domain -> service` is the whole model.

## Goals

- A developer can open one dashboard and inspect the whole workspace.
- A domain, service, worker, or function can be filtered without knowing
  Kubernetes names.
- Self-hosted users get the same shape as future Sun-hosted users.
- Sun commands point at the shared surface while opening scoped dashboards
  for domains and services.

## Identity

Every log line, metric, trace, deploy event, and generated dashboard link
must carry the same ownership identity:

| Label | Meaning |
|---|---|
| `workspace` | Company/product workspace name |
| `env` | Environment, for example `dev`, `staging`, `prod` — determined by which target the CLI is currently pointed at (kubeconfig context / deploy target), not a CLI path segment |
| `domain` | Business domain/team slice, for example `payments` |
| `service` | Service, worker, or function name |
| `primitive` | `svc`, `worker`, or `fn` |
| `release` | Deployed image/release identity when known |

> **Status:** `workspace`/`domain`/`service`/`primitive`/`release` are
> emitted today (OBS-008). `env` is not yet emitted — `sun up`/`sun deploy`
> have no target-resolution concept at all (no `--target`, nothing threaded
> through `Sun_cli_deployment_plan`), so there's nothing to source a value
> from without inventing a second, disconnected notion of "target" (e.g. a
> standalone `--env` flag) that would immediately diverge from `sun.yml`'s
> target config. The fix, when it happens, is wiring real `--target`
> resolution into `sun up`/`sun deploy` — the same path `sun plan`/
> `sun cloud tf` already use (`Sun_cli_config.load_for_target`) and
> `sun status`/`sun logs`/`sun open` now use for `observability_backend`/
> `base_domain` (OBS-015) — with `env = target.env`. Not a standalone
> `--env` flag.

These labels are the API. Kubernetes namespaces, pod names, Helm release
names, bucket names, and cloud resource names are implementation details.

## Backend Modes

Sun supports three observability backend modes:

| Mode | Use |
|---|---|
| `local` | Dev and throwaway clusters. In-cluster Loki, Prometheus, and Grafana. No durability promise. |
| `self_hosted_durable` | Production self-hosting in the user's cloud account. Durable logs and metrics with object storage. |
| `external` | Bring-your-own observability provider. Sun ships logs/metrics to the configured endpoints. |

The mode changes storage and transport. It should not change the product
surface: `sun status`, `sun logs`, and `sun open` should keep using the same
workspace/domain/service scopes.

## CLI Shape

`sun status` is deterministic from any directory inside the workspace. The
current working directory is only used to find the workspace root.

```bash
sun status
sun status payments
sun status payments/charge-svc
```

At workspace scope, show an index:

```text
sun workspace

Domains
  payments   healthy
  comms      degraded
  logistics  not deployed

Observability
  backend  self_hosted_durable
  logs     healthy
  metrics  healthy

Open
  logs       sun open logs
  metrics    sun open metrics
  dashboard  sun open dashboard
```

At domain scope, show service health and the shared observability surface:

```text
payments  self_hosted_durable  healthy

Services
  charge-svc    healthy
  refund-svc    degraded

Observability
  logs       healthy
  metrics    healthy
  dashboard  healthy

Open
  logs       sun open logs payments
  metrics    sun open metrics payments
  dashboard  sun open dashboard payments
```

At service scope, open the service-specific dashboard and logs view:

```text
payments/charge-svc  healthy

Observability
  logs       healthy
  metrics    healthy
  dashboard  healthy

Open
  logs       sun open logs payments/charge-svc
  metrics    sun open metrics payments/charge-svc
  dashboard  sun open dashboard payments/charge-svc
```

`Open` entries are commands, not URLs. A `--links` flag can print raw URLs for
copying or automation:

```text
Links
  logs       https://grafana.acme.com/explore?...
  metrics    https://grafana.acme.com/d/...
  dashboard  https://grafana.acme.com/
```

## Dashboard Shape

Grafana is the default self-hosted dashboard shell today. Sun should provision
one workspace dashboard entrypoint plus scoped dashboards:

- workspace overview
- domain overview
- service dashboard for service-specific metrics
- service logs view
- deploy/release timeline when available

The dashboard should filter by Sun labels, not by namespace/pod names. A
single incident often crosses an HTTP service, Kafka worker, scheduled
function, database, and deploy event — cross-domain search is the point.

## Hosted Path

Future Sun-hosted observability should keep the same shape:

```text
workspace/domain/service
```

Sun may operate the storage itself or broker a managed provider behind the
scenes. Users should not have to learn that backend in the happy path. The
self-hosted durable path exists to build trust and avoid lock-in; the hosted
path exists to remove operations work.

## Non-Goals

- No separate observability stack per service.
- No CLI wrapper around every Loki or Prometheus query feature.
- No product promise that `local` preserves history.
- No provider-specific UX as the core model.
- No `project` layer above `domain` — see the note under Goals.
