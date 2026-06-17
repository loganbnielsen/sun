---
id: CODEX_STYLE_AUDIT-021
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-021/flatten-generated-startup
worktree: /home/lbendtly/Code/sun-CODEX-021
---

Flatten generated app main startup configuration.

**Depends on:** CODEX_STYLE_AUDIT-020.

**Problem:** Example/generated app entrypoints use nested option/result matches
for Loki, Postgres, migrations, Kafka service creation, and registration:

- `examples/pluto/app/comms/notify_worker/bin/main.ml:6-24`
- `examples/pluto/app/payments/charge_svc/bin/main.ml:5-23`
- `examples/venus/app/comms/notify_worker/bin/main.ml:9-34`
- `examples/venus/bin/run.ml:89-130`

**Goal:** Make scaffolded startup code linear and easy for application engineers
to modify.

**Acceptance criteria:**

- Introduce template helpers for `env_nonempty`, optional backend creation, and
  DB pool creation.
- Use Result/Option combinators or small helpers to reduce nested matches.
- Keep generated runtime behavior and error messages compatible.
