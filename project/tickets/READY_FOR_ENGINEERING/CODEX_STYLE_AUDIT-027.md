---
id: CODEX_STYLE_AUDIT-027
type: refactor
severity: high
source: style audit
---

Represent Kafka SASL requirements in the type instead of optional fields.

**Depends on:** CODEX_STYLE_AUDIT-026.

**Problem:** `Kafka_security.t` stores `sasl_mechanism`, `sasl_username`, and
`sasl_password` as independent options while `protocol` decides whether they are
required. `kafka_security.ml:50-59` performs runtime checks to reject invalid
combinations.

**Goal:** Encode valid security configurations in the type.

**Acceptance criteria:**

- Replace the flat record with variants for plaintext, TLS, SASL plaintext, and
  SASL over TLS.
- Ensure SASL constructors require mechanism, username, and password.
- Keep optional CA location on TLS-capable variants.
- Update tests and config application.
