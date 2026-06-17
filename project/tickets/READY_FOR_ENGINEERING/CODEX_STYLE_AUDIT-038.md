---
id: CODEX_STYLE_AUDIT-038
type: refactor
severity: high
source: style audit
---

Validate storage table and column identifiers before SQL construction.

**Depends on:** none.

**Problem:** `integrations/storage/sun-storage/lib/table.ml:3-5` accepts `table`,
`id_column`, and `columns` as raw strings, then interpolates them into SQL at
`table.ml:17-34`. Caqti parameters protect values, not identifiers.

**Goal:** Introduce a validated SQL identifier type for schema modules.

**Acceptance criteria:**

- Add an identifier constructor that rejects empty or unsafe table/column names.
- Change `SCHEMA` to expose validated identifiers or validate once when the
  functor is applied.
- Add tests for invalid table and column names.
