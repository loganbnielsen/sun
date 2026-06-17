---
id: CODEX_STYLE_AUDIT-061
type: refactor
severity: high
source: docs/audits/STYLE_AUDIT.md
---

Make the deployment compiler pipeline explicit in code.

**Depends on:** none.

**Problem:** `docs/architecture/PRODUCT_ARCHITECTURE.md` describes deployment as
`workspace scan -> application model -> environment resolution -> deployment plan
-> executor`, but implementation is spread across `cmd_up.ml`, `cmd_deploy.ml`,
`Sun_cli_manifest`, `Sun_cli_deployment_plan`, `Sun_cli_deployment_render`, and
`Sun_cli_executor`. Contributors have to trace CLI parsing, env defaults,
rendering, apply, GitOps emit, and state updates manually to understand the
pipeline.

**Goal:** Create a clear deployment compiler module boundary that makes each
phase inspectable and testable.

**Acceptance criteria:**

- Introduce a small orchestration module, for example `Sun_cli_deployment_pipeline`,
  with typed phases: `request -> resolved_environment -> plan -> artifacts ->
  execution_result`.
- Move shared sequencing out of `cmd_up.ml` and `cmd_deploy.ml` where practical.
- Keep local, direct, GitOps, and hosted paths consuming the same plan type.
- Add tests for at least plan construction and artifact rendering without
  shelling out to Kubernetes.
