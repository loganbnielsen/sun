---
id: CODEX_STYLE_AUDIT-020
type: refactor
severity: medium
source: style audit
---

Make scaffolded JSON decoders typed and reusable.

**Depends on:** none.

**Problem:** Generated example/template code repeats ad hoc JSON lookup helpers
using raw strings and nested matches, for example
`cli/sun/lib/sun_cli_scaffold_templates.ml:442-444` and
`cli/sun/lib/sun_cli_scaffold_templates.ml:502-536`. The same patterns appear in
generated app code under `examples/pluto` and `examples/venus`.

**Goal:** Improve generated user-facing code so new projects start with typed,
readable decoders.

**Acceptance criteria:**

- Extract or generate small Result-returning JSON field helpers.
- Avoid defaulting missing fields to `""` or `0` when the field is required.
- Update scaffold golden tests to expect the safer generated code.
- Keep existing example applications compiling.
