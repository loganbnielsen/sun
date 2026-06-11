# Post-Dogfood Gameplan

Dogfood Alpha proved the non-hosted product loop end to end: install, scaffold,
local substrate, local deploy, migration, status, logs, rollback, customer-cloud
manifest export, and the first release binary.

The next phase should make the production path harder to misuse and easier to
operate, then turn the hosted mock boundary into a believable managed product.

## Direction

Sun is driving toward one product model with four ownership lanes:

- Local Dev: Sun owns the laptop substrate loop.
- Managed Customer Cloud: Sun owns the standard substrate shape inside the
  customer's cloud account.
- Exported Self-Managed: Sun emits artifacts; the customer owns apply, drift,
  and overlays.
- Sun Hosted: Sun owns substrate, builders, registry, URLs, TLS, logs, release
  history, and billing guardrails.

The next features should strengthen that model rather than add arbitrary
deployment flexibility. The goal is a production platform that makes the secure,
observable, typed-event architecture the default.

## Feature Track 1: GitOps And Secrets Hardening

Status: in progress. `FEAT-019` already redacts all `stringData` values in
GitOps output. The remaining hardening is to remove placeholder Secret manifests
as the primary GitOps interface and generate backend references instead.

First tickets:

- `FEAT-020`: GitOps secret backend references.
- Follow-up: optional SealedSecrets rendering once the External Secrets path is
  stable.
- Follow-up: docs and CI guard that fail if emitted GitOps YAML contains
  non-empty `stringData` values.

Why this comes first: exported self-managed GitOps is the highest-risk lane
because generated artifacts are designed to be committed. It must be impossible
for Sun's default command to leak credentials into git history.

## Feature Track 2: Deployment Plan Completeness

Status: ready for engineering. `--emit-plan-to` currently carries services and
environment identity, but dogfood showed empty `topics` and `migrations`.

First tickets:

- `FEAT-021`: scan workspace event contracts and migration files into the
  deployment plan.
- Follow-up: classify migrations as pending/applied when a database URL is
  available.
- Follow-up: include topic ownership, consumer groups, and schema subjects so a
  reviewer can understand event contract impact before deploy.

Why this matters: Sun's customer-cloud contract depends on reviewing a plan
before applying it. A plan that omits topics and migrations cannot support
change management, release inspection, or hosted deploy diagnostics.

## Feature Track 3: Release-Grade Installation

Status: ready for engineering. The Linux binary is published, but the
install still requires a cloned Sun checkout and `SUN_HOME` for templates.

First tickets:

- `FEAT-022`: bundle scaffold/runtime templates into the release artifact or
  install them beside the binary.
- Follow-up: release macOS arm64 and Linux arm64 binaries.
- Follow-up: install script with version pinning, checksum verification, and
  upgrade behavior.

Why this matters: a public alpha cannot ask users to understand the framework
repo layout before `sun new workspace` works. The release artifact should be the
product, not just the CLI executable.

## Feature Track 4: Day-2 Operations From Sun Commands

Status: ready for engineering. Dogfood found the core ops loop works, but the
user still needs Grafana knowledge for Loki-routed logs and there are
path/rollout rough edges.

First tickets:

- `FEAT-023`: `sun logs` should print or open a Grafana LogQL URL when stdout
  logs are incomplete.
- Follow-up: unify service path formats across `sun up`, `sun logs`, and
  `sun rollback`.
- Follow-up: force a rollout restart when a fixed image tag is reused with new
  content.

Why this matters: Sun's promise is not just deployment. A small team should
debug, roll back, and inspect services through Sun before dropping to raw
Kubernetes or Grafana.

## Feature Track 5: Hosted Product Reality

Status: design and mock boundary complete. The hosted executor, release model,
release inspection, default URLs, custom-domain design, project registry, deploy
API contract, and release history model are implemented as local/stubbed
contracts.

First tickets after hardening:

- Replace in-memory hosted registry with a durable Postgres-backed control-plane
  store.
- Add a real builder/registry handoff for `sun cloud deploy`.
- Add authentication and account/environment isolation to hosted APIs.
- Connect hosted release logs to the same inspection model used by
  customer-cloud plans.

Why this waits: hosted should be "Sun runs the same platform for you." The
non-hosted path needs hardening first so hosted does not become a separate
product shape.

## Suggested Order

1. Finish GitOps secrets hardening beyond redaction (`FEAT-020`).
2. Make deployment plans complete enough for review (`FEAT-021`).
3. Make the release artifact self-contained (`FEAT-022`).
4. Polish the day-2 ops loop (`FEAT-023` and follow-ups).
5. Run the release-user dogfood (`ALPHA-001`).
6. Run the public alpha docs/readiness audit (`ALPHA-002`).
7. Expand the deployment plan into the release-review contract (`FEAT-024`).
8. Run the post-alpha security/reliability audit (`HARDEN-001`).
9. Cut a post-hardening alpha release (`RELEASE-001`).
10. Smoke-test the published release artifact (`RELEASE-002`).
11. Reconcile public docs from the release smoke test (`RELEASE-003`).
12. Resume hosted implementation using the same plan/release primitives
    (`CLOUD-004` and follow-ups).

## Public Alpha Release Readiness

Status: ready for engineering. The dogfood and hardening sweep is complete, but
the public artifact should be republished after the security fixes and checked
from a clean user environment.

First tickets:

- `RELEASE-001`: prepare and publish `v0.1.0-alpha.5`.
- `RELEASE-002`: install and smoke-test the published release artifact.
- `RELEASE-003`: patch public docs for any release-user mismatches.

Why this comes before more hosted work: the release artifact is the public
contract. Hosted work should build on the same release, plan, and inspection
model that a non-hosted alpha user can actually install and verify.

## Hosted Realization Wave

Status: ready after the alpha release is republished and verified. The hosted
contracts exist, but the implementation is still stubbed around in-memory state
and fake build/registry handoff.

First tickets:

- `CLOUD-004`: replace the in-memory hosted registry with durable Postgres
  control-plane storage.
- `CLOUD-005`: add a real hosted builder and registry handoff path.

Why these are next: they turn "Sun Hosted" from API shape into product behavior
without changing the ownership model proven by the customer-cloud and exported
self-managed paths.

## Engineer Verification Tickets

The verification work is intentionally ticketed. Engineers should be able to run
the commands, collect output, and decide pass/fail without product archaeology.

- `ALPHA-001`: release-user dogfood from the self-contained release bundle.
- `ALPHA-002`: public alpha documentation and release readiness audit.
- `FEAT-024`: deployment plan v2 release-review contract.
- `HARDEN-001`: post-alpha security and reliability audit.
