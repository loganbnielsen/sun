# sun-storage audit

Pre-extraction audit for `integrations/storage/sun-storage`, written the same way
`obs-audit.md` was written before the observability extraction: decide what must be
fixed before this could become a standalone OPAM package, not what an ideal ORM might
eventually contain.

**Status (2026-08-25): blockers 1–4 fixed in place, then extracted to the standalone
`pg-eio` package** (`github.com/loganbnielsen/pg-eio`, pinned from `~/Code/pg-eio`).
`integrations/storage/sun-storage/` is gone from this repo; every consumer now depends
on `pg-eio` instead. See `docs/planning/WORK_SUMMARY.md`'s "sun-storage extracted to the
standalone `pg-eio` opam package" entry for the full account. The checklist below is
left as a record of what extraction required, not a still-open TODO.

## Short version

`sun-storage` (`Storage_error`, `Db`, `Migration`, `Table`) is a thin, opinionated layer
directly over `caqti` / `caqti-eio` / `caqti-driver-postgresql` — all already-published,
independently-maintained OPAM packages. That's a different shape from `kafka-eio` and
`obs-eio`, which were Sun-authored protocol/FFI code with no existing generic package to
lean on. There is no analogous "generic binding vs. Sun policy" split to make here the
way `kafka-eio-core` (extracted) split from `kafka-eio-service` (stayed) — `sun-storage`
is closer in spirit to `kafka-eio-service`: it's all policy, just policy with zero Sun
framework coupling (confirmed: no reference to `Sun_svc`/`Obs`/`Kafka` anywhere in
`integrations/storage/sun-storage/lib/`). That absence of coupling is what makes it
*possible* to extract, not evidence that it *should* be — that's a product call for
whoever owns Sun's roadmap.

If extracted, the package is genuinely reusable outside Sun: any Eio + Postgres project
wants a pool wrapper, a migration runner, and a typed-row functor.

## Pre-extraction blockers

1. **SQL injection surface in `Migration`'s `~table` parameter.**

   `Table.Make` validates `table`/`id_column`/every column name through
   `Table.Identifier.of_string` (`[A-Za-z_][A-Za-z0-9_]*`, rejects everything else,
   `lib/table.ml:17-64`) before it ever reaches a `Printf.sprintf`-built query.
   `Migration.apply`/`status`/`rollback` take a `?table` parameter with the exact same
   shape and the exact same `Printf.sprintf "... %s ..." tbl` construction
   (`lib/migration.ml`: `ensure_table`, `applied_versions`, `record_migration`,
   `applied_at_q`, `last_applied_q`, `delete_version_q`) — but never validate it.

   Today's only caller (`sun migrate`) derives the table name from a workspace
   directory name, so this isn't exploitable through Sun's own CLI today. But it's a
   public `?table:string` parameter on a library that would be published for reuse —
   the next caller doesn't get that protection for free. This is the same category of
   issue `obs-audit.md` flagged in `obs-eio` (negative counter deltas, `"le"` label
   collision): the core type signature allows something the implementation silently
   assumes never happens.

   Recommendation: route `~table` through `Table.Identifier.of_string` (or a shared
   copy of it — `Migration` doesn't currently depend on `Table`) before building any
   query, and return `Storage_error.Migration_error` on rejection instead of raising or
   emitting broken SQL.

2. **`Db.transaction` discards rollback failures.**

   `lib/db.ml`, `transaction`: `Error _ -> ignore (C.rollback ()); result`. If the
   rollback itself fails (connection dropped mid-transaction, etc.), that failure is
   silently thrown away — the caller sees only the original error and has no signal
   that the transaction may not have actually rolled back.

   Recommendation: at minimum, log the rollback failure through some caller-supplied
   hook; consider folding it into the returned error (e.g.
   `Storage_error.Query_error` wrapping both messages) since silently mis-reporting
   transaction state is a data-integrity concern, not just an ergonomics one.

3. **`Identifier` validation lives in `Table`, not in a place `Migration` can share.**

   Not a bug today, but worth fixing before extraction rather than after: two copies of
   the same validator is exactly the kind of thing that drifts. Move `Identifier` (and
   maybe `Limit`/`Offset`) into `Storage_error`-adjacent shared code, or a small
   internal module both `Table` and `Migration` depend on.

4. **No tests for the two issues above.** `test/test_storage.ml` has 8 tests (2 unit +
   6 integration, per `sun-storage.md`) — worth confirming none of them exercise an
   unsafe `~table` value or a rollback-of-rollback failure before claiming this is
   release-ready. (Not independently verified in this pass — flagging as a checklist
   item, see below.)

Everything else in `lib/` is in good shape: `Db` correctly hides the caqti pool's type
variable behind a polymorphic record field, `exec`/`find`/`collect` map errors
consistently, `Migration`'s SQL statement splitter handles quoted strings, comments, and
dollar-quoted PL/pgSQL bodies (real Postgres-specific correctness work, not naive
`String.split_on_char ';'`), and `Table.Make`'s `Limit`/`Offset` guard against
pathological `list` calls.

## Current dependency shape

```text
uri, caqti, caqti-eio, caqti-eio.unix, caqti-driver-postgresql
```

Already minimal — no Sun framework dependency, no dependency beyond what a Postgres+Eio
pool wrapper needs. `caqti-eio.unix` is required specifically because
`caqti-driver-postgresql` is a C-binding driver; a pure `pgx`-backed setup wouldn't need
it. Nothing to trim here.

## Package shape (proposed — needs a naming decision)

The `kafka-eio` / `obs-eio` family uses a `<domain>-eio` naming convention. This package
doesn't have an obvious one-word domain the way `kafka` or `obs` do — candidates:

- `pg-eio` — short, matches driver scope (Postgres specifically, matching
  `caqti-driver-postgresql`), but undersells the migration runner and `Table.Make`.
- `caqti-toolkit-eio` / `caqti-pg-eio` — signals the caqti dependency directly, avoids
  implying this is a general multi-backend ORM (it explicitly isn't — `sun-storage.md`
  lists "multiple database backends" as out of scope).
- Keep `sun-storage` as the published name even though it's Sun-agnostic in practice —
  lowest naming-churn option, but slightly misleading for a package with no actual Sun
  dependency.

Recommend `pg-eio` unless the migration runner and `Table.Make` are considered
first-class enough to want in the name too — that's a judgment call, not something to
decide unilaterally here.

Public modules would carry over as-is: `Storage_error`, `Db`, `Migration`, `Table`
(module names, not the library/opam name, so no `Obs`-style collision-driven rename is
obviously needed — `Db` and `Table` are more collision-prone generic names than `Obs`
was, worth a second look before committing).

## Extraction checklist (none of this is started)

- [ ] Fix blockers 1–3 above while the code still lives in `sun`.
- [ ] Confirm test coverage for the `Migration` `~table` injection path and the
      rollback-of-rollback path (blocker 4).
- [ ] Decide the package name.
- [ ] Standalone `dune-project`/opam file, `public_name`, `CHANGES.md`, `LICENSE`,
      `README.md` with examples that don't reference Sun internals.
- [ ] Run the full test suite against a real Postgres instance from a clean checkout
      (`platform/local/scripts/ensure-postgres.sh` gives the local recipe to mirror).
- [ ] Tag and opam-pin, the same way `obs-eio`/`obs-loki-eio`/`obs-prometheus-eio` were.
- [ ] Only then cut `sun` over — delete `integrations/storage/sun-storage/`, add the
      pinned package to `dune-project`/`sun.opam`, rewire every consumer
      (`examples/pluto/app/comms/notify_worker`, the CLI scaffold templates, etc. —
      same shape of sweep as the just-completed obs cutover).

## What not to do

- Don't add multi-backend support (MySQL/SQLite) to justify a more generic name — the
  spec explicitly scopes this to Postgres.
- Don't add an update/upsert helper or query builder as part of extraction — both are
  explicitly out of scope in `sun-storage.md` and unrelated to release-readiness.
