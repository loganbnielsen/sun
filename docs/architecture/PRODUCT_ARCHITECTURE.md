# Sun Product Architecture

Sun is an open-source OCaml software factory for backend systems. It is not only
a runtime framework and not only a deployment CLI; it is the productized path
from typed domain code to running production services.

The product has four layers:

1. **User workspace repo** — the application source of truth: domain events,
   service code, workers, functions, migrations, and high-level service config.
2. **Sun open-source factory** — the framework libraries, CLI control surface,
   scaffold templates, deployment compiler, local dev tooling, and infrastructure
   modules.
3. **Generated production artifacts** — Dune projects, Docker images, Kubernetes
   manifests, GitOps output, deployment plans, release metadata, and observability
   wiring.
4. **Sun hosted factory floor** — the future managed service layer: projects,
   environments, builders, clusters, registries, secrets, deploy history, domains,
   logs, rollbacks, previews, RBAC, audit logs, and billing.

The first three layers exist today. The hosted factory floor is the product
direction: it should shape deployment architecture, but it should not force a
detailed control-plane API before the factory contract is stable.

---

## Source of Truth

The **user workspace repo is always the source of truth** for application structure:

```text
events/<domain>/                 typed event contracts owned by publishing teams
app/<domain>/<name>_<primitive>/ service, worker, and function code
db/migrations/                   database migrations
sun.toml                         high-level service overrides
```

Sun compiles the workspace into runtime artifacts:

- Kubernetes namespaces, Deployments, Services, CronJobs, NetworkPolicies, and Secrets
- Kafka topics, schema registrations, consumer groups, and ACL intent
- service identity, metrics labels, log labels, and trace ownership fields
- image names and release identity
- migration plan and migration tracking table

Generated infrastructure is a build artifact. Users should not need to commit
hand-written per-service Kubernetes YAML, Dockerfiles, or CI deployment glue for
normal workflows.

---

## Factory Responsibilities

The Sun CLI is the control panel, not the whole factory. Each command triggers
one part of a larger automated pipeline:

| Factory stage | Sun responsibility |
|---|---|
| Scaffold | Generate workspaces, services, workers, functions, events, tests, Dockerfiles, and CI templates |
| Build | Compile OCaml via Dune and prepare container image inputs |
| Package | Standardize Docker image shape and registry/image naming |
| Plan | Turn workspace structure and environment inputs into a typed deployment plan |
| Synthesize | Render Kubernetes, GitOps, secret references, rollout shape, and observability wiring |
| Execute | Apply locally, emit artifacts, or submit to a future hosted executor |
| Operate | Status, logs, migrations, secrets, rollback, and release inspection |

Framework libraries (`sun-svc`, `sun-worker`, `sun-fn`) are the runtime contract
layer inside that factory. Supporting libraries (`*-eio`) are factory machinery:
their public APIs should expose domain operations and explicit results, not raw
transport handles, hidden parsers, or implementation escape hatches.

---

## Ownership Lanes

Sun should support three current ownership lanes plus one future hosted lane
over the same application model.

### Local Dev

The user runs Sun on their machine.

```bash
sun dev up
sun up
```

Sun provisions or connects to a local k3d-backed platform, builds images, renders runtime artifacts, applies them locally, and starts port-forwards.

### Managed Customer Cloud

The customer owns the cloud account and cluster.

Sun may help provision infrastructure with Terraform wrappers or guides, but the
customer's account owns the cluster, registry, DNS, secrets backend, and cloud
bill. Sun owns the standard substrate shape and release workflow.

Deployments may be direct:

```bash
sun deploy --env prod
```

### Exported Self-Managed

The customer owns apply, drift, overlays, and operations. Sun still compiles the
workspace into Terraform/manifests/GitOps artifacts, but those artifacts become
handoff output rather than a Sun-operated release.

```bash
sun deploy --env prod --emit-to <gitops-repo>
```

### Sun Hosted Factory Floor

Sun owns the hosting environment and operates the factory floor.

The user's workspace repo still remains the source of truth, but Sun owns environment resolution, builds, registries, clusters, secrets, deploy execution, release records, logs, rollbacks, domains, and billing.

The desired commercial product path is:

```text
connect Git provider
select workspace repo
create environment
deploy
observe
rollback
```

The CLI should be able to interact with this mode, but the first architectural
priority is making hosted deployment another executor over the same deployment
plan. Hosted Sun should run the same factory contract, not become a second
application model.

---

## Ownership Matrix

| Concern | Local Dev | Managed Customer Cloud | Exported Self-Managed | Future Sun Hosted |
|---|---|---|---|---|
| Application source | user workspace repo | user workspace repo | user workspace repo | user workspace repo |
| Build execution | local CLI | customer CI or CLI | customer CI or CLI | Sun |
| Deployment execution | local CLI | Sun CLI/CI in customer account | customer GitOps/apply path | Sun hosting plane |
| Cluster | local k3d | customer | customer | Sun |
| Registry | local k3d registry | customer | customer | Sun |
| Kafka / schema registry | local Redpanda | customer-managed or Sun-installed in customer cluster | customer-managed | Sun-managed |
| Postgres | local/in-cluster | customer RDS, Cloud SQL, or in-cluster | customer-managed | Sun-managed |
| Secrets | local/dev placeholders | customer secret backend | generated references/placeholders | Sun secret backend |
| Domains / TLS | localhost | customer DNS | customer DNS | Sun-managed DNS/TLS |
| Observability | local Grafana/Loki/Prometheus | customer cluster | customer-managed | Sun-hosted views backed by managed telemetry |
| Deploy history | local output | Sun release inspection over customer apply | emitted plan/artifact history | Sun release records |
| Rollback | local CLI | Sun CLI/GitOps | customer operation | Sun hosting plane |
| Billing | none | customer cloud bill | customer cloud bill | Sun |

Observability is a shared workspace surface, not one dashboard per service. See
[`observability-design.md`](observability-design.md) for the label model,
backend modes, and `sun status` / `sun open` UX.

---

## Deployment Compiler

Sun treats deployment as a compiler pipeline:

```text
workspace scan
  -> application model
  -> environment resolution
  -> deployment plan
  -> executor
```

Today, manifest rendering is close to:

```text
workspace scan -> YAML -> apply or emit
```

That works for local and early GitOps flows, but it will not scale cleanly to a
hosted factory floor. The key architectural object is a typed, serializable
deployment plan.

---

## Deployment Plan

A deployment plan represents what Sun intends to run for a workspace in a specific environment.

It should be:

- typed in OCaml
- serializable for CI and hosted-control-plane use
- deterministic for a given workspace, environment, and image set
- inspectable before apply
- executable by multiple deployment backends

Minimum shape:

```ocaml
type deployment_mode =
  | Local
  | Customer_cloud
  | Sun_hosted

type environment = {
  name : string;
  mode : deployment_mode;
  region : string option;
  registry : string;
  base_domain : string option;
}

type service_spec = {
  domain : string;
  name : string;
  primitive : [ `Svc | `Worker | `Fn ];
  image : string;
  config : (string * string) list;
  secrets : string list;
}

type topic_spec = {
  owner_domain : string;
  name : string;
  schema_subject : string;
}

type deployment_plan = {
  workspace : string;
  environment : environment;
  services : service_spec list;
  topics : topic_spec list;
  migrations : string list;
}
```

This is illustrative, not final API. The important point is that local deploy, GitOps deploy, customer-cloud deploy, and Sun-hosted deploy should consume the same plan.

---

## Executors

Executors apply a deployment plan.

| Executor | Input | Output |
|---|---|---|
| Local executor | deployment plan | applies manifests to local k3d cluster |
| Direct Kubernetes executor | deployment plan | applies manifests to current kube context |
| GitOps executor | deployment plan | writes manifests to a GitOps repo |
| Future Sun hosted executor | deployment plan | submits or applies through Sun hosting plane |

Executor differences should be operational, not architectural. If two executors need different application models, the compiler pipeline is leaking.

---

## Environment Resolution

Environment-specific values must be separated from application source.

Application-owned:

- service primitive and domain
- route definitions and auth intent
- event contracts
- migrations
- high-level overrides in `sun.toml`

Environment-owned:

- registry
- image tag
- cluster
- region
- base domain
- Kafka endpoint and security
- Postgres URL
- observability endpoints
- secret values
- managed service placement

For local and customer-cloud modes, environment config can live in local files or CI variables. For Sun-hosted mode, environment config comes from the hosting plane.

---

## Hosted Factory Floor Direction

The hosted factory floor should eventually manage:

- accounts and teams
- projects and workspace repo connections
- environments
- builds and image registry
- deployment plans
- releases and rollback history
- secrets
- managed databases, Kafka, and observability
- custom domains and TLS
- billing and usage

Do not build or over-specify this layer before the deployment plan is stable.
The near-term goal is to make hosted deployment possible by ensuring deployment
is compiled into a stable plan that a future control plane can execute and
record.

---

## Near-Term Implementation Priorities

1. Add a typed `Deployment_plan` module.
2. Refactor manifest rendering to consume a deployment plan instead of raw discovered services.
3. Make `sun up` and `sun deploy --emit-to` use the same plan.
4. Add an environment config model for local and customer-cloud deploys.
5. Keep Sun-hosted deployment as a documented executor direction until the plan shape is stable.

---

## Open Decisions

These are intentionally not settled yet:

- Whether Sun-hosted builds pull directly from Git providers or receive artifacts from customer CI.
- Whether hosted runtime clusters are single-tenant, multi-tenant, or mixed by customer tier.
- Which secrets backend Sun-hosted mode uses.
- Whether customer-cloud mode is a first-class product path or an advanced/self-managed path.
- How custom domains and TLS are provisioned in Sun-hosted mode.
- How billing maps to projects, environments, services, usage, and managed resources.
- Whether GitOps remains a core hosted mechanism or only a customer-cloud option.

The current product bias is:

- local dev should be excellent;
- Sun-hosted should become the paid managed factory floor;
- customer-cloud should remain possible, but should not complicate the default user experience.
