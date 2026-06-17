---
id: CODEX_STYLE_AUDIT-033
type: refactor
severity: medium
source: style audit
---

Share TLS authenticator setup across Kafka, Prometheus, and Loki clients.

**Depends on:** none.

**Problem:** TLS CA bundle discovery and HTTPS wrapper construction is duplicated
in `kafka_service_http.ml`, `obs_prometheus.ml`, and `obs_loki.ml`, each with
similar nested `match` handling and string-specific error messages.

**Goal:** Provide one typed TLS helper module used by all Eio HTTP clients.

**Acceptance criteria:**

- Extract system CA bundle discovery and `Tls_eio` wrapper creation into a shared
  module.
- Return typed errors instead of raising `failwith` where practical.
- Preserve fail-closed behavior when no CA bundle exists.
