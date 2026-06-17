---
id: CODEX_STYLE_AUDIT-035
type: refactor
severity: medium
source: style audit
---

Represent buffered log entries structurally instead of flattening magic keys.

**Depends on:** none.

**Problem:** `Obs.flatten_logs` emits `"log.level"` and `"log.msg"` magic keys,
and `obs_loki.ml:137-157` reconstructs log entries by splitting on those string
keys. This is fragile stringly-typed coupling between modules.

**Goal:** Keep span log entries as structured values through backend emission.

**Acceptance criteria:**

- Add a `log_entry` record type to `Obs.span_event`.
- Emit `log_entries : log_entry list` instead of flattened magic fields.
- Update stdout and Loki backends to render from the structured list.
- Preserve current log output shape where tests depend on it.
