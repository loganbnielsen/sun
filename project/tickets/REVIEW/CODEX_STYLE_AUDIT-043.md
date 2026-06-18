---
id: CODEX_STYLE_AUDIT-043
type: refactor
severity: low
source: style audit
---

Replace process `exit_code : int` with a typed process status.

**Depends on:** CODEX_STYLE_AUDIT-042.

branch: CODEX_STYLE_AUDIT-043/process-status-type
worktree: /home/lbendtly/Code/sun-CODEX-043

**Problem:** `tools/sun_process/lib/sun_process.ml:1-5` stores only
`exit_code : int`, flattening normal exits and signal deaths into integers via
`exit_of_status`.

**Goal:** Preserve process termination semantics in the type.

**Acceptance criteria:**

- Add a status variant for exited, signaled, and stopped.
- Provide a helper for shell-compatible numeric exit code where needed.
- Update tests and callers that inspect `.exit_code`.
