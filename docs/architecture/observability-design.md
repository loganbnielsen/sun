# Observability Design

Sun treats observability as a workspace-level capability, not a per-service
add-on. A Sun workspace is a company monorepo: many projects, environments,
domains, services, workers, and functions all emit into the same observability
surface.

The product rule is:

```text
one workspace -> one logs backend, one metrics backend, one dashboard surface
```

Individual projects and services are scoped views inside that surface, selected
by stable labels. A service can and should have its own dashboard; it should
not have its own isolated observability stack.

## Goals

- A developer can open one dashboard and inspect the whole workspace.
- A project, environment, domain, service, worker, or function can be filtered
  without knowing Kubernetes names.
- Self-hosted users get the same shape as future Sun-hosted users.
- Sun commands point at the shared surface while opening scoped dashboards for
  projects and services.

## Identity

Every log line, metric, trace, deploy event, and generated dashboard link must
carry the same ownership identity:

| Label | Meaning |
|---|---|
| `workspace` | Company monorepo/workspace name |
| `project` | Product or app inside the monorepo |
| `env` | Environment, for example `dev`, `staging`, `prod` |
| `domain` | Business domain/team slice, for example `payments` |
| `service` | Service, worker, or function name |
| `primitive` | `svc`, `worker`, or `fn` |
| `release` | Deployed image/release identity when known |

These labels are the API. Kubernetes namespaces, pod names, Helm release names,
bucket names, and cloud resource names are implementation details.

## Backend Modes

Sun supports three observability backend modes:

| Mode | Use |
|---|---|
| `local` | Dev and throwaway clusters. In-cluster Loki, Prometheus, and Grafana. No durability promise. |
| `self_hosted_durable` | Production self-hosting in the user's cloud account. Durable logs and metrics with object storage. |
| `external` | Bring-your-own observability provider. Sun ships logs/metrics to the configured endpoints. |

The mode changes storage and transport. It should not change the product
surface: `sun status`, `sun logs`, and `sun open` should keep using the same
workspace/project/service scopes.

## CLI Shape

`sun status` is deterministic from any directory inside the workspace. The
current working directory is only used to find the workspace root.

```bash
sun status
sun status pluto/prod
sun status pluto/prod/payments/charge-svc
```

At workspace scope, show an index:

```text
sun workspace

Projects
  pluto    prod  healthy
  venus    prod  degraded
  mercury  dev   not deployed

Observability
  backend  self_hosted_durable
  logs     healthy
  metrics  healthy

Open
  logs       sun open logs
  metrics    sun open metrics
  dashboard  sun open dashboard
```

At project/environment scope, show service health and the shared observability
surface:

```text
pluto/prod  self_hosted_durable  healthy

Services
  payments/charge-svc    healthy
  comms/notify-worker    degraded

Observability
  logs       healthy
  metrics    healthy
  dashboard  healthy

Open
  logs       sun open logs pluto/prod
  metrics    sun open metrics pluto/prod
  dashboard  sun open dashboard pluto/prod
```

At service scope, open the service-specific dashboard and logs view:

```text
pluto/prod/payments/charge-svc  healthy

Observability
  logs       healthy
  metrics    healthy
  dashboard  healthy

Open
  logs       sun open logs pluto/prod/payments/charge-svc
  metrics    sun open metrics pluto/prod/payments/charge-svc
  dashboard  sun open dashboard pluto/prod/payments/charge-svc
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
- project/environment overview
- service dashboard for service-specific metrics
- service logs view
- deploy/release timeline when available

The dashboard should filter by Sun labels, not by namespace/pod names. For a
monorepo, cross-service search is the point: a single incident often crosses an
HTTP service, Kafka worker, scheduled function, database, and deploy event.

## Hosted Path

Future Sun-hosted observability should keep the same shape:

```text
workspace/project/env/domain/service
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
