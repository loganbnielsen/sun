# Observability Backends

`platform/infra/base`'s `observability_backend` variable selects where Loki
(logs) and Prometheus (metrics) data lives. Sun ships a self-hosted durable
path so production users are not forced into Sun-hosted observability.
The product design is documented in
[`docs/architecture/observability-design.md`](../architecture/observability-design.md).

| Profile | Logs (Loki) | Metrics (Prometheus) | Requires |
|---|---|---|---|
| `local` (default) | In-cluster, optional PVC | In-cluster, optional PVC | Nothing. For dev and throwaway clusters. |
| `external` | Skipped entirely; promtail ships straight to your endpoint | Still runs (it's the scrape agent) but forwards via `remote_write`, short local retention | `external_loki_url` + `external_prometheus_remote_write_url` (and usernames/passwords if your endpoint needs basic auth) |
| `self_hosted_durable` | In-cluster Loki, chunks + index in S3 | Prometheus + Thanos sidecar/storegateway/compactor backed by S3 | AWS only — see below |

## `external`

Points promtail's log-shipping client and Prometheus's `remote_write` at
infrastructure you already run or already pay for (a hosted Loki/Prometheus
service, your own observability stack elsewhere, etc.). Sun's Grafana +
local Loki are skipped since there's nothing local left to browse; Prometheus
itself keeps running because it's the thing doing the scraping, just with a
couple hours of local retention instead of the usual 15 days.

```hcl
observability_backend                = "external"
external_loki_url                    = "https://logs-prod-000.grafana.net/loki/api/v1/push"
external_loki_username               = "123456"
external_loki_password               = "<api key>"
external_prometheus_remote_write_url = "https://prometheus-prod-000.grafana.net/api/prom/push"
external_prometheus_username         = "123456"
external_prometheus_password         = "<api key>"
```

**Known gap:** `sun logs`'s Loki client (`Sun_cli_loki`, OBS-002) sends
unauthenticated queries. If your `external` target requires an API key on
reads (most hosted Loki services do), `sun logs` will fail through to its
`kubectl logs` fallback rather than actually querying your external Loki.
Not fixed in this pass — file a follow-up if you need it.

## `self_hosted_durable` (AWS only)

Production self-hosted observability in the user's AWS account.
Object-storage-backed Loki keeps logs in S3. Prometheus writes blocks through
a Thanos sidecar; Thanos Query reads current blocks from the sidecar and
historical blocks from storegateway, with compactor managing object-store
block growth. GCP is a deliberate gap, not an oversight.

This is two Terraform states with no automatic link between them (same as
`cert_manager_irsa_role_arn` already works): apply `platform/infra/aws` with
durable observability enabled, read its outputs, then pass them into
`platform/infra/base`.

```bash
# platform/infra/aws
terraform apply -var=enable_durable_observability=true ...

terraform output loki_s3_bucket      # -> loki_s3_bucket
terraform output loki_irsa_arn       # -> loki_irsa_role_arn
terraform output thanos_s3_bucket    # -> thanos_s3_bucket
terraform output thanos_irsa_arn     # -> thanos_irsa_role_arn
```

```hcl
# platform/infra/base
observability_backend = "self_hosted_durable"
aws_region             = "us-east-1"
loki_s3_bucket         = "<from loki_s3_bucket output>"
loki_irsa_role_arn     = "<from loki_irsa_arn output>"
thanos_s3_bucket       = "<from thanos_s3_bucket output>"
thanos_irsa_role_arn   = "<from thanos_irsa_arn output>"
```

**What it costs:** S3 storage plus the in-cluster Loki, Prometheus, Thanos
Query, storegateway, and compactor pods. Both buckets have a 90-day expiration
lifecycle rule by default; change it if you need longer retention.

**Teardown:** the Loki and Thanos S3 buckets use Terraform `prevent_destroy`
so retained logs and metrics are not deleted as part of a cluster teardown.
To intentionally delete them, remove that lifecycle guard and empty/delete the
buckets explicitly.

**Why Thanos over Mimir (OBS-007):** the write path bolts onto the Prometheus
deployment Sun already runs, and the read path only needs Query,
storegateway, and compactor. Mimir can come later if ingestion scale demands
it.

**Known gap:** the full S3-backed path has not been exercised against a live
cluster. This pass is still static Terraform/Helm validation only; run a real
AWS deploy before depending on it in production.

## Dashboards (OBS-011)

All three profiles provision the same two Grafana dashboards, loaded via the
`loki-stack` chart's sidecar ConfigMap-loading (`grafana.sidecar.dashboards`)
rather than one file per domain/service:

- **Workspace overview** — request rate, 5xx rate, and scraped-target health
  across every domain at once.
- **Service template** — one dashboard parameterized by `$domain`/`$service`
  Grafana template variables (populated live from Prometheus label values,
  not a list Sun maintains). Selecting values re-scopes every panel,
  including a Loki logs panel filtered to that domain/service.

A Prometheus datasource is provisioned the same way the chart already
auto-provisions its own "Loki" datasource (a ConfigMap labeled
`grafana_datasource: "1"`), since nothing wired Grafana to Prometheus before
this ticket.

**Known gaps:**
- Only `-svc` primitives get a `prometheus.io/scrape` annotation today (a
  containerPort actually exists to scrape). `-worker` has no metrics port
  wired at the manifest level yet — a pre-existing gap, not introduced or
  fixed here — so the service template's `$service` dropdown will only ever
  populate with `-svc` names until that's addressed separately. `-fn` uses
  Pushgateway, a different ingestion path this ticket doesn't touch.
- A per-service **logs view** and a **deploy/release timeline** dashboard
  (both mentioned in `docs/architecture/observability-design.md`) are not
  built — deferred, not silently dropped.
- **Not verified against a live Grafana instance.** This pass validated the
  dashboard JSON is well-formed and the Terraform/Helm wiring
  (`terraform validate`, chart values checked against `helm show values`),
  but did not run a real `sun dev up` and confirm the panels/variables
  actually render and populate. Flagged explicitly — do this before trusting
  the dashboards in a real review.
