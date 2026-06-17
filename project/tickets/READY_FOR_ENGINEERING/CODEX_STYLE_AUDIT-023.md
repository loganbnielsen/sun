---
id: CODEX_STYLE_AUDIT-023
type: refactor
severity: medium
source: style audit
---

Replace route pattern strings with a typed route pattern representation.

**Depends on:** none.

**Problem:** `framework/sun-svc/lib/route.ml:4-15` stores route patterns as raw
strings, and `route.ml:34-60` reparses `":"` parameters at match time. Bad
patterns compile and only fail by convention.

**Goal:** Parse route patterns at construction time and expose a typed pattern to
the router.

**Acceptance criteria:**

- Add a `Route.pattern` type with literal and parameter segments.
- Make `get`, `post`, `put`, `patch`, and `delete` parse and validate patterns.
- Preserve the current public ergonomics or provide a clear migration helper.
- Update route tests to cover malformed patterns and parameter extraction.
