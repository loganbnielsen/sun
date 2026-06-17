---
id: CODEX_STYLE_AUDIT-028
type: refactor
severity: medium
source: style audit
---

Replace Kafka service HTTP option pairs with a request record.

**Depends on:** none.

**Problem:** `integrations/kafka/kafka-eio-service/lib/kafka_service_http.ml:55`
passes `~meth ~base_url ~path ~content_type_opt ~body_opt` through the HTTP
client. `content_type_opt` and `body_opt` must move together for POST/PUT, but
the type permits mismatched states.

**Goal:** Model Kafka admin/schema-registry HTTP requests as typed records or
variants.

**Acceptance criteria:**

- Introduce a request type that distinguishes GET without body from methods with
  body and content type.
- Update `http_get`, `http_post`, and `http_put` to construct that type.
- Keep timeout and TLS behavior unchanged.
