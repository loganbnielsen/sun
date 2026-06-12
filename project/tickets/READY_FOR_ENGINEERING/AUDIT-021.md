---
id: AUDIT-021
type: audit-finding
severity: medium
source: project/audits/2026-06-11_audit.md
---

`sun migrate rollback` is a non-functional stub

**Depends on:** None.

**Description:** `run_rollback` in `cli/sun/bin/cmd_migrate.ml` (lines 79–82) unconditionally prints "not yet implemented" and exits 1. The subcommand appears in `sun migrate --help` and was added to the Tutorial CLI reference in RELEASE-003, misleading users who attempt to roll back a migration.

**Impact:** Users who run `sun migrate rollback` get a stub error instead of functionality. CI automation that calls `sun migrate rollback` on failure produces a confusing failure message.

**Remediation:** Implement rollback in `migration.ml` — track each applied migration's SQL or require a companion down-migration file (e.g., `0001_notifications.down.sql`). Alternatively, remove the subcommand from the public CLI surface and update docs to explain that rollback requires a manual down-migration SQL file applied directly.
