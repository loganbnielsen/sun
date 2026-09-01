# Live/Dev Deploy Roadmap

Goal: make Sun feel like a simple software factory for local dev and live
deploys without hiding cost, state, or rollback risk.

## Current Reality

- `sun dev up` creates the local substrate.
- `sun up` builds every discovered Dockerfile-backed service and applies
  Kubernetes manifests.
- `sun cloud plan/apply` creates customer-cloud substrate with Terraform.
- `sun cloud destroy` tears that substrate down with Terraform.
- `sun deploy` applies pre-built image tags or emits GitOps manifests.
- Changed-service detection is manual today: pass a service path, or all
  services are deployed.
- `-fn` deploys as Kubernetes `CronJob`; Lambda deployment is not wired into
  Sun's deploy path.

## Project 1: Safe Cloud Dogfood

Prove the live AWS path without surprise spend.

Completion criteria:

- `sun cloud plan dev/aws/us-east-1` shows a reviewable plan.
- `sun cloud apply dev/aws/us-east-1` provisions the low-cost dev stack.
- Printed outputs are enough to configure kubectl and registry login.
- `sun cloud destroy dev/aws/us-east-1 --plan` previews teardown.
- `sun cloud destroy dev/aws/us-east-1 --apply` completes.
- A read-only AWS CLI verification step confirms EKS, RDS, and ECR resources are gone.
- A dated dogfood report records commands, failures, fixes, and rough cost.

Tests:

- No unit test should hit AWS.
- Terraform adapter argv tests cover init, plan, apply, plan-destroy, destroy.
- Live test uses the smoke-test tfvars and IAM policy only.

## Project 2: Changed-Service Build And Deploy

Deploy only what changed unless the user asks for everything.

Completion criteria:

- `sun build --changed --base <ref>` prints and builds impacted services.
- `sun deploy --changed --base <ref>` deploys only impacted services.
- Changes under shared framework/runtime paths trigger all services.
- Changes under `events/` trigger affected workers, or all workers until topic
  ownership is explicit enough to narrow safely.
- Manual service path filtering keeps working.
- Default `sun up` behavior stays simple and predictable.

Tests:

- Workspace fixture with multiple services.
- Git-diff path classifier tests for service-local, shared, event, docs-only,
  and unknown-path changes.
- Dry-run output proves unchanged services are skipped.

## Project 3: Target Files

Make app topology explicit at the root and deployment placement explicit in
target files whose paths carry env/provider/region.

Target model:

- `sun.yml` is the source of truth for project, services, resources,
  resource-specific shape, and service/resource bindings.
- `sun/<env>/<provider>/<region>.yml` is the deploy target file.
- Target identity is derived from the path, for example
  `prod/aws/us-east-1`; provider and region are not repeated inside the YAML.
- A target file owns its regional instance set. A resource named `app_db` in
  two target files means two physical regional instances of the same logical
  resource.
- Code discovery fills in boring facts like service paths and generated
  service type; it does not guess costly topology.
- Costly decisions stay explicit: provider, regions, clusters, managed
  resources, indexes, backups, and scale.
- Cross-region resource references are reserved as absolute refs:
  `/us-east-1/analytics_db`. They mean same env/provider remote access, not
  replication.
- Cross-env resource sharing is forbidden. Cross-provider references are
  reserved for later and must not work by accident.
- V1 supports local `uses` refs only. Cross-region sharing and replication are
  separate later features.

Target CLI:

```sh
sun plan dev/aws/us-east-1
sun deploy dev/aws/us-east-1

sun cloud plan prod/aws/us-east-1
sun cloud apply prod/aws/us-east-1
sun cloud destroy prod/aws/us-east-1
```

Completion criteria:

- `sun.yml` can define services, resources, and service `uses` bindings.
- DynamoDB resources require declared keys and indexes; they are never inferred
  from code.
- `sun/<env>/<provider>/<region>.yml` can override registry, base domain,
  resource sizing, and service scale.
- `sun plan <env>/<provider>/<region>` prints the merged app/resource/service
  plan before Terraform or kubectl runs.
- `sun cloud plan <env>/<provider>/<region>` resolves provider, region, and
  Terraform variables from the merged Sun config.
- `sun deploy <env>/<provider>/<region> --image-tag <tag>` resolves registry and target
  metadata from the merged Sun config.
- CLI flags still override target file values.
- Missing required target values fail before Terraform or kubectl runs.

Tests:

- Parser tests for valid and invalid `sun.yml` and override files.
- Merge tests for base config plus `sun/<env>/<provider>/<region>.yml`.
- Command request tests for target file plus CLI override precedence.
- Dry-run tests prove resolved regions, resources, indexes, registry, and
  base-domain land in the plan.

Config rules:

- File path carries placement. `sun/prod/aws/us-east-1.yml` means
  `env=prod`, `provider=aws`, `region=us-east-1`.
- YAML carries topology and overrides: resources, services, bindings, scale,
  sizing, public exposure, durability, and provider-specific knobs.
- Provider-specific fields stay boxed under `aws:` or `gcp:`. Promote a field
  to generic Sun language only when it has stable meaning across providers.
- Local `uses` refs address resources in the selected target. Absolute refs
  use `/<region>/<resource>` and address resources in another region of the
  same env/provider. `sun plan` must print them as cross-region access.
- Refs containing an env segment, such as `/prod/aws/us-east-1/db`, are invalid;
  cross-env sharing is not supported.
- Refs containing a provider segment, such as `/gcp/us-central1/db`, are
  reserved for future multi-cloud support and rejected in v1.
- Cross-target access is not replication. Replication requires explicit future
  language such as `replica_of` or `replicate_from`.
- Folder config and nested YAML are two projections of the same logical model;
  adding split/flat formatters later must not change deploy semantics.

## Project 4: Worker Retry Contract

Make Kafka failure behavior explicit before production users invent variants.

Completion criteria:

- Worker config supports max attempts and local retry backoff.
- Failed messages go to `<topic>.dlq` after attempts are exhausted.
- DLQ events include original topic, partition, offset, attempt count, error,
  and first-seen timestamp.
- Successful DLQ publish commits the original offset.
- Handlers are documented as requiring idempotency.

Tests:

- Unit test for retry count and backoff decision.
- Redpanda integration test for DLQ publish plus original offset commit.
- Failure test where DLQ publish fails and the original offset is not committed.

## Project 5: Release/Upgrade Loop

Make deploy, inspect, rollback, and upgrade understandable from Sun commands.

Completion criteria:

- Every deploy writes a local or remote release record with service image refs.
- `sun status` shows desired tag, live tag, rollout state, and age.
- `sun rollback <service>` works for Deployments and Rollouts.
- CronJobs report as non-rollout workloads instead of pretending rollback works.
- Reusing a fixed tag forces a rollout restart or is rejected with a clear fix.

Tests:

- Release record serialization tests.
- Kubernetes command adapter tests for restart/status/rollback.
- Dry-run fixture showing status/rollback behavior for svc, worker, and fn.

## Not Yet

- Active-active multi-region.
- Automatic cross-region Kafka failover.
- Lambda deploys from Sun.
- A hosted control plane.

Add these when the single-region Kubernetes path is proven live and boring.
