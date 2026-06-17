---
id: CODEX_STYLE_AUDIT-030
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-030/typed-topic-partition-query
worktree: /home/lbendtly/Code/sun
---

Return typed topic metadata errors instead of `None` from Redpanda admin parsing.

**Depends on:** none.

**Problem:** `integrations/kafka/kafka-eio-service/lib/kafka_service_intf.ml:41-56`
returns `None` for connection errors, HTTP 404, JSON parse failures, missing
fields, and unexpected statuses. These are different states collapsed into one
option.

**Goal:** Distinguish topic-not-found from admin API failures and malformed
responses.

**Acceptance criteria:**

- Replace `query_topic_partitions` return type with a Result carrying
  `Topic_not_found` or `Topic_partitions of int`.
- Update `Kafka_service.register` partition guard logic.
- Add tests for malformed admin responses if existing HTTP test support allows.
