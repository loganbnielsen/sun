---
id: CODEX_STYLE_AUDIT-024
type: refactor
severity: high
source: style audit
branch: CODEX_STYLE_AUDIT-024/jwt-verification-mode
worktree: /home/lbendtly/Code/sun-CODEX-024
---

Replace `allow_unverified_v1_unsafe` boolean with an explicit JWT verification mode.

**Depends on:** none.

**Problem:** `framework/sun-svc/lib/auth.ml:2-5` exposes
`allow_unverified_v1_unsafe : bool`. This is a high-risk boolean trap in an auth
API: `true` disables signature verification, and a call site has to remember what
the flag means.

**Goal:** Make unsafe JWT behavior impossible to enable accidentally.

**Acceptance criteria:**

- Replace the boolean with a variant such as `Verified of verifier_config` or
  `Unverified_dev_only`.
- Make unsafe mode visually explicit at call sites and in tests.
- Preserve current behavior for existing tests by updating them to the explicit
  constructor.

## Review — automated checks passed
Focused auth/service tests pass. The boolean trap is replaced by explicit jwt_verification constructors, unsafe call sites now use Unverified_dev_only, and existing HTTP behavior is preserved.
