---
id: CODEX_STYLE_AUDIT-066
type: refactor
severity: high
source: docs/audits/STYLE_AUDIT.md
---

Add first-class plan, diff, and apply semantics for deployment changes.

**Depends on:** CODEX_STYLE_AUDIT-061.

**Problem:** `sun deploy` supports `--dry-run`, `--emit-plan-to`, and `--emit-to`,
but the user-facing and internal lifecycle does not present an obvious
plan/diff/apply model. CI/CD engineers expect to inspect intended changes before
mutation and to understand exactly what the cluster or GitOps repo will receive.

**Goal:** Make change intent explicit before execution.

**Acceptance criteria:**

- Define internal types for `plan`, `rendered_artifacts`, and `change_set`.
- Add or prepare command surfaces for plan/diff/apply semantics without changing
  existing flags prematurely.
- Ensure dry-run and emit-plan paths use the same plan object as apply.
- Add tests proving dry-run performs no executor side effects.
