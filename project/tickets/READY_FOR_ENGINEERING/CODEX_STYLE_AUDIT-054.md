---
id: CODEX_STYLE_AUDIT-054
type: refactor
severity: medium
source: style audit
---

Type hosted cost attribution provider, resource kind, billing period, and currency.

**Depends on:** none.

**Problem:** `cli/sun/lib/sun_cli_hosted_model.ml:58-71` stores cost attribution
domains such as `provider`, `resource_kind`, `billing_period`, and `currency` as
strings. Only currency is validated later.

**Goal:** Make billing/cost metadata domains explicit.

**Acceptance criteria:**

- Add variants or validated wrappers for provider, resource kind, billing period,
  and currency.
- Move parsing/validation into constructors.
- Preserve JSON output strings.
