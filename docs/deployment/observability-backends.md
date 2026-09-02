# Observability Backends

`platform/infra/base`'s `observability_backend` variable selects where Loki
(logs) and Prometheus (metrics) data lives. Sun does not choose a vendor here
— that's a decision for whoever operates the target, or for a future Sun
Cloud lane to make on a customer's behalf without this interface changing.

| Profile | Logs (Loki) | Metrics (Prometheus) | Requires |
|---|---|---|---|
| `local` (default) | In-cluster, optional PVC | In-cluster, optional PVC | Nothing — today's behavior. |
| `external` | Skipped entirely; promtail ships straight to your endpoint | Still runs (it's the scrape agent) but forwards via `remote_write`, short local retention | `external_loki_url` + `external_prometheus_remote_write_url` (and usernames/passwords if your endpoint needs basic auth) |
| `self_managed_durable` | In-cluster Loki, chunks + index in S3 | In-cluster Prometheus + a Thanos sidecar uploading TSDB blocks to S3 | AWS only — see below |

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

## `self_managed_durable` (AWS only)

Object-storage-backed Loki and a Thanos sidecar on Prometheus, so log/metric
history survives pod rescheduling and cluster teardown/recreate. GCP is a
deliberate gap, not an oversight — pick this up if/when a GCP target needs
it.

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
observability_backend = "self_managed_durable"
aws_region             = "us-east-1"
loki_s3_bucket         = "<from loki_s3_bucket output>"
loki_irsa_role_arn     = "<from loki_irsa_arn output>"
thanos_s3_bucket       = "<from thanos_s3_bucket output>"
thanos_irsa_role_arn   = "<from thanos_irsa_arn output>"
```

**What it costs:** S3 storage (cheap per-GB) plus whatever compute the
existing Loki/Prometheus pods already use — the sidecar and object storage
don't add meaningfully to compute cost. Both buckets have a 90-day expiration
lifecycle rule by default; change it if you need longer retention.

**Teardown:** `terraform destroy` on `platform/infra/aws` deletes the S3
buckets (and everything in them) along with the rest of the target. If you
want logs/metrics to outlive a cluster teardown, move the bucket out of that
Terraform state (or add `prevent_destroy`) before destroying.

**Why Thanos sidecar over Mimir (OBS-007):** bolts onto the Prometheus
deployment Sun already runs instead of replacing it, and
`prometheus-community/prometheus` (the chart Sun already uses) has
first-class support for it (`server.sidecarContainers`,
`server.service.gRPC`) — no new Helm chart to operate for the write path.

**Known gaps, not required by OBS-005/006/007's acceptance criteria:**

- Only a Thanos **Query** component is deployed, pointed at the sidecar's
  StoreAPI. There's no **storegateway** reading directly from S3, so once
  Prometheus's own local retention evicts a block, it stops being queryable
  even though it's already durably stored — this is a read-path gap, not a
  data-loss one. Add a storegateway pointed at the same bucket as a
  follow-up if you need to query further back than local retention.
- No **compactor** — S3 block count grows unbounded over time (a cost/ops
  concern, not a correctness one).
- Loki's `storage_config`/`schema_config` values were written against
  Grafana's documented object-storage architecture and confirmed against
  this chart version's default values (`helm show values grafana/loki-stack
  --version 2.10.2`), but the full S3-backed path has **not been exercised
  against a live cluster** — this ticket's verification was `terraform
  validate` only. Confirm against a real deploy before depending on it in
  production.
