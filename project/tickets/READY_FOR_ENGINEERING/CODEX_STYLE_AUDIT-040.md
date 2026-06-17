---
id: CODEX_STYLE_AUDIT-040
type: refactor
severity: medium
source: style audit
---

Replace event `topic_name : string` contracts with typed topic descriptors.

**Depends on:** none.

**Problem:** `Kafka_service_intf.MESSAGE` exposes `val topic_name : string`, and
event modules under `examples/` repeat raw string topics. A typo or invalid topic
name compiles and fails at runtime.

**Goal:** Represent Kafka topics with a validated topic-name type.

**Acceptance criteria:**

- Add a topic-name constructor with Kafka-compatible validation.
- Update `MESSAGE`, `topic`, and sample event modules to use it.
- Keep string conversion at the Kafka raw/admin boundary.
