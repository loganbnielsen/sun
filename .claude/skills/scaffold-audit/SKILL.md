---
description: Run a scaffold quality audit of Sun. Verifies every sun new template compiles, preserves domain ownership, uses framework lifecycles, keeps security defaults, and gives AI agents a predictable working surface. Produces a dated report in project/audits/ and materialises open findings as ticket files in project/tickets/READY_FOR_ENGINEERING/.
---

# /scaffold-audit — Scaffold Quality Audit

Works through every section of `docs/audits/SCAFFOLD_AUDIT.md`. Writes a completed report to `project/audits/<YYYY-MM-DD>_scaffold_audit.md` and materialises each open finding as a ticket in `project/tickets/READY_FOR_ENGINEERING/`.

The core question: *does `sun new ...` generate code we would be comfortable making the default pattern for every startup using Sun?*

## Ticket IDs

Use `SCAFFOLD-NNN`, continuing from the highest existing `SCAFFOLD-*` ID across `project/audits/` and all `project/tickets/` subdirectories.

## Steps

### 1. Read the template

Read `docs/audits/SCAFFOLD_AUDIT.md` in full before starting.

### 2. Check previous findings

Read the most recent `project/audits/*_scaffold_audit.md` report if one exists. Check all `project/tickets/` subdirectories for existing `SCAFFOLD-*` ticket files. Do not re-materialise a finding already tracked anywhere.

### 3. Inspect scaffold implementation

- Read `cli/sun/bin/cmd_new.ml`
- Read `cli/sun/lib/sun_cli_scaffold.ml`
- Read `cli/sun/lib/sun_cli_workspace.ml`
- Identify every template and generated file path for workspace, svc, worker, fn, and event scaffolds

### 4. Generate fresh scaffolds

Use a clean temporary directory and run the executable runbook from `docs/audits/SCAFFOLD_AUDIT.md` where practical:

```bash
sun new workspace scaffold_audit
cd scaffold_audit
eval $(opam env) && dune build
sun new svc payments/refund
sun new worker logistics/fulfillment
sun new fn billing/invoice
sun new event billing/payment_confirmed
eval $(opam env) && dune build
```

If a command cannot be run because dependencies or local infrastructure are unavailable, inspect the template source and record the reproduction gap separately.

### 5. Verify generated semantics

- Check service templates use `Sun.Service.Make` and explicit route auth
- Check worker templates use `Sun.Worker.Make`, import event contracts, and call `ack()` only after side effects
- Check function templates use `Sun.Fn.Make` and return result values
- Check event templates live under `events/<domain>/` and satisfy the message contract
- Check generated docs avoid stale commands and repo-local scripts
- Check `sun.toml`, Dockerfile, and deployment metadata preserve Sun defaults

### 6. Write the report

Create `project/audits/<YYYY-MM-DD>_scaffold_audit.md` with:
- A header showing the date and previous-finding status changes
- Each section with `[x]` / `[ ]` checklist results
- A Findings section with `Status: Open` or `Status: Resolved`
- A summary table

### 7. Materialise tickets

For each open finding not already tracked, create `project/tickets/READY_FOR_ENGINEERING/<id>.md`:

```markdown
---
id: <SCAFFOLD-NNN>
type: scaffold-finding
severity: <critical|high|medium|low>
source: project/audits/<YYYY-MM-DD>_scaffold_audit.md
---

<one-line title>

**Description:** <from finding>

**Impact:** <from finding>

**Remediation:** <from finding>
```

Do not set `branch:` or `worktree:`.
