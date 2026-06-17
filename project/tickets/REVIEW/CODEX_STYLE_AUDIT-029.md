---
id: CODEX_STYLE_AUDIT-029
type: refactor
severity: high
source: style audit
branch: CODEX_STYLE_AUDIT-029/schema-registry-response-decoders
worktree: /home/lbendtly/Code/sun
---

Centralize Schema Registry response decoding with typed response records.

**Depends on:** none.

**Problem:** `integrations/kafka/kafka-eio-service/lib/kafka_service_schema.ml`
repeats nested JSON parsing for compatibility and registration responses at
lines 8-27 and 60-72. Required fields such as `"is_compatible"` and `"id"` are
raw string lookups.

**Goal:** Decode Schema Registry responses through reusable typed helpers.

**Acceptance criteria:**

- Add Result-returning decoders for compatibility and registration responses.
- Replace nested `Yojson.Safe.from_string` matches with these helpers.
- Preserve current error messages or update tests to assert the new structured
  messages.
