# Sun Product Architecture

Sun is an OCaml production platform for startups. The product has three layers:

1. **Sun framework repo** — the framework, CLI, scaffold templates, service primitives, deployment compiler, local dev tooling, and infrastructure modules.
2. **User workspace repo** — the application source of truth: domain events, service code, workers, functions, migrations, and high-level service config.
3. **Sun hosting plane** — the future managed service layer: projects, environments, clusters, registries, secrets, deploy history, domains, logs, rollbacks, and billing.

The first two layers exist today. The third is the product direction and should shape deployment architecture, but it should not force a detailed control-plane API before the product decisions are ready.

---

## Source of Truth

The **user workspace repo is always the source of truth** for application structure:

```text
events/<domain>/                 typed event contracts owned by publishing teams
app/<domain>/<name>_<primitive>/ service, worker, and function code
db/migrations/                   database migrations
sun.toml                         high-level service overrides
```

Sun derives runtime artifacts from that workspace:

- Kubernetes namespaces, Deployments, Services, CronJobs, NetworkPolicies, and Secrets
- Kafka topics, schema registrations, consumer groups, and ACL intent
- service identity, metrics labels, log labels, and trace ownership fields
- image names and release identity
- migration plan and migration tracking table

Generated infrastructure is a build artifact. Users should not need to commit hand-written per-service Kubernetes YAML for normal workflows.

---

## Deployment Modes

Sun should support three deployment modes over the same application model.

### Local Dev

The user runs Sun on their machine.

```bash
sun dev up
sun up
```

Sun provisions or connects to a local k3d-backed platform, builds images, renders runtime artifacts, applies them locally, and starts port-forwards.

### Customer Cloud

The customer owns the cloud account and cluster.

Sun may help provision infrastructure with Terraform wrappers or guides, but the customer's account owns the cluster, registry, DNS, secrets backend, and cloud bill.

Deployments may be direct:

```bash
sun deploy --env prod
```

Or GitOps-based:

```bash
sun deploy --env prod --emit-to <gitops-repo>
```

### Sun Hosted

Sun owns the hosting environment.

The user's workspace repo still remains the source of truth, but Sun owns environment resolution, builds, registries, clusters, secrets, deploy execution, release records, logs, rollbacks, domains, and billing.

The desired product path is:

```text
connect Git provider
select workspace repo
create environment
deploy
observe
rollback
```

The CLI should be able to interact with this mode, but the first architectural priority is making hosted deployment another executor over the same deployment plan.

---

## Ownership Matrix

| Concern | Local Dev | Customer Cloud | Sun Hosted |
|---|---|---|---|
| Application source | user workspace repo | user workspace repo | user workspace repo |
| Build execution | local CLI | customer CI or CLI | Sun |
| Deployment execution | local CLI | customer CLI, CI, or GitOps | Sun hosting plane |
| Cluster | local k3d | customer | Sun |
| Registry | local k3d registry | customer | Sun |
| Kafka / schema registry | local Redpanda | customer-managed or Sun-installed in customer cluster | Sun-managed |
| Postgres | local/in-cluster | customer RDS, Cloud SQL, or in-cluster | Sun-managed |
| Secrets | local/dev placeholders | customer secret backend | Sun secret backend |
| Domains / TLS | localhost | customer DNS | Sun-managed DNS/TLS |
| Observability | local Grafana/Loki/Prometheus | customer cluster | Sun-hosted views backed by managed telemetry |
| Deploy history | local output | customer CI/GitOps | Sun release records |
| Rollback | local CLI | customer CLI/GitOps | Sun hosting plane |
| Billing | none | customer cloud bill | Sun |

---

## Deployment Compiler

Sun should treat deployment as a compiler pipeline:

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

That works for local and early GitOps flows, but it will not scale cleanly to hosted deployment. The key architectural object is a typed, serializable deployment plan.

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
| Sun hosted executor | deployment plan | submits or applies through Sun hosting plane |

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

## Hosting Plane Direction

The hosting plane should eventually manage:

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

Do not build or over-specify this layer before the deployment plan exists. The near-term goal is to make hosted deployment possible by ensuring deployment is compiled into a stable plan that a future control plane can execute and record.

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
- Sun-hosted should become the primary hosted product path;
- customer-cloud should remain possible, but should not complicate the default user experience.
