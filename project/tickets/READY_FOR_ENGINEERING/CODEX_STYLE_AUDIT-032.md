---
id: CODEX_STYLE_AUDIT-032
type: refactor
severity: medium
source: style audit
---

Validate observability metric and label names before rendering.

**Depends on:** none.

**Problem:** `Obs.metric_event` and Prometheus rendering accept `name` and label
keys as raw strings. `obs_prometheus.ml:151-169` concatenates them directly into
Prometheus exposition format.

**Goal:** Use refined metric and label names so invalid output cannot be emitted.

**Acceptance criteria:**

- Add constructors for metric names and label names that validate Prometheus
  naming rules.
- Use validated names in `Obs.register_counter`, `register_gauge`, and
  `register_histogram`.
- Update tests for invalid names and existing valid metrics.
