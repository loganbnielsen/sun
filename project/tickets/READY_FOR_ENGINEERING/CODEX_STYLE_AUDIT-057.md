---
id: CODEX_STYLE_AUDIT-057
type: refactor
severity: medium
source: style audit
---

Flatten secret set/list/delete namespace flows with Result helpers.

**Depends on:** CODEX_STYLE_AUDIT-056.

**Problem:** `cli/sun/lib/sun_cli_secret.ml:188-277` deeply nests validation,
mode parsing, namespace checks, Kubernetes reads, manifest rendering, patching,
and restart side effects.

**Goal:** Make secret operations readable as Result pipelines.

**Acceptance criteria:**

- Add helper functions for validating operation context and iterating namespaces.
- Use Result binding for sequential operations.
- Preserve current redacted output and restart behavior.
