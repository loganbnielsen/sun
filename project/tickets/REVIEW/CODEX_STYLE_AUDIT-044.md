---
id: CODEX_STYLE_AUDIT-044
type: refactor
severity: high
source: style audit
---

Replace deployment-plan `secret_backend : string` with the existing backend variant.

**Depends on:** none.

branch: CODEX_STYLE_AUDIT-044/typed-secret-backend-plan
worktree: /home/lbendtly/Code/sun-CODEX-044

**Problem:** `cli/sun/lib/sun_cli_deployment_plan.ml:7-15` defines
`env_config.secret_backend : string`, even though `Sun_cli_manifest.secret_backend`
is a variant. The plan serializes a finite deployment behavior as raw text.

**Goal:** Keep secret backend typed until JSON serialization.

**Acceptance criteria:**

- Change `env_config.secret_backend` to a variant or reuse
  `Sun_cli_manifest.secret_backend`.
- Update env-target conversion and deploy plan JSON rendering.
- Keep existing JSON string values stable.
