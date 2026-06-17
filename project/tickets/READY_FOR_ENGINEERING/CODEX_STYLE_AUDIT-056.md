---
id: CODEX_STYLE_AUDIT-056
type: refactor
severity: high
source: style audit
---

Make secret environment mode parsing explicit instead of defaulting unknown values.

**Depends on:** none.

**Problem:** `cli/sun/lib/sun_cli_secret.ml:7-13` maps unknown environment strings
to `Customer_cloud`. A typo in `--env` can silently target the wrong secret
management path.

**Goal:** Treat secret environment mode as a finite parsed domain.

**Acceptance criteria:**

- Change `mode_of_env` to return `(mode, string) result`.
- Update `set`, `list`, and `delete` to handle unknown modes explicitly.
- Keep accepted aliases documented and tested.
