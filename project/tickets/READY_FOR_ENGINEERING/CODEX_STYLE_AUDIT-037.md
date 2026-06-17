---
id: CODEX_STYLE_AUDIT-037
type: refactor
severity: low
source: style audit
---

Centralize trace header names and make extraction case-insensitive.

**Depends on:** none.

**Problem:** `integrations/observability/obs-eio/lib/obs_trace.ml:41-47` hardcodes
`"traceparent"` in both extract and inject paths. Header case behavior depends on
the caller-provided list.

**Goal:** Make trace propagation use a single typed header constant and robust
lookup helper.

**Acceptance criteria:**

- Add a `traceparent_header` constant or small header module.
- Use case-insensitive lookup/replacement for header lists.
- Update trace tests to cover mixed-case incoming headers.
