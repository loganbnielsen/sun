---
id: CODEX_STYLE_AUDIT-036
type: refactor
severity: medium
source: style audit
---

Make `Obs.register_*` enforce declared label names.

**Depends on:** CODEX_STYLE_AUDIT-032.

**Problem:** `integrations/observability/obs-eio/lib/obs.ml:171-189` accepts
`~label_names` but ignores it. Emitters can later pass any `(string * string)`
labels, defeating the registration contract.

**Goal:** Use the compiler/runtime boundary to catch label set mistakes.

**Acceptance criteria:**

- Store declared label names in the returned emitter closure.
- Reject or report missing, extra, or duplicate labels on emission.
- Update tests to cover correct and incorrect label sets.
