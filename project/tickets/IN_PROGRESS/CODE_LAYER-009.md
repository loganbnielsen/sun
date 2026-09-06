---
id: CODE_LAYER-009
type: bug
severity: low
source: project/audits/2026-09-06_code_layer_audit.md
branch: CODE_LAYER-009/remove-legacy-render-path
worktree: ../sun-CODE_LAYER-009-remove-legacy-render-path
---

**Depends on:** None.

## Problem

`sun up` and `sun deploy` both build a `Sun_cli_deployment_plan.service_spec`
and render it through `Sun_cli_deployment_render.render_spec` (called from
`Sun_cli_executor.local`/`run_plan`) — that is the one real manifest
rendering path in the CLI today.

Separately, `sun_cli_manifest_yaml.ml` still carries a second, full
orchestration function — `render ?toml svc ~workspace ~ns ~name ~image`
(re-exported as `Sun_cli_manifest.render` via `include Sun_cli_manifest_yaml`
and declared in `sun_cli_manifest.mli`) — that duplicates `render_spec`'s
primitive/progressive-delivery matching almost line for line, driven
directly off `Sun_cli_toml.t` instead of a `service_spec`.

A repo-wide search turns up exactly one caller of this function anywhere in
`cli/sun`: `test/test_manifest_render.ml:451`, inside
`test_svc_render_spec_matches_render` — a test whose entire purpose,
by its own name and comment, is proving `render_spec` produces the same YAML
as this "legacy render path". No CLI command, executor, or scaffold path
calls `Sun_cli_manifest.render` today. `sun_cli_manifest.mli`'s comment above
the low-level doc builders ("used by render and render_spec") is now
inaccurate — only `render_spec`, via `Sun_cli_deployment_render`, uses them
going forward.

Per this repo's no-backwards-compatibility policy, a superseded
orchestration path has no reason to remain public API (re-exported through
a `.mli`) purely to backstop a parity test for a migration that has already
finished.

## Goal

`Sun_cli_manifest`'s public surface reflects the one rendering path that is
actually used; no dead orchestration code, no test whose only job is
comparing live code against dead code.

## Remediation

- Delete `Sun_cli_manifest_yaml.render` (the `?toml svc ~workspace ~ns ~name
  ~image` function, roughly lines 569-637 of `sun_cli_manifest_yaml.ml`).
- Remove `render`'s declaration from `sun_cli_manifest.mli` and fix the
  now-stale comment above the low-level doc builders to say they're used by
  `Sun_cli_deployment_render.render_spec` (via `Sun_cli_manifest`'s
  re-export), not by a `render` that no longer exists.
- Delete `test_svc_render_spec_matches_render` from
  `test/test_manifest_render.ml`. If the goal was to lock down
  `render_spec`'s output shape against regressions, that's already covered
  by the many other direct `render_spec_ok`-based assertions in the same
  file — add a focused golden-output test there instead if a gap remains,
  rather than keeping a comparison against code being deleted.

## Acceptance criteria

- `Sun_cli_manifest_yaml.render` no longer exists.
- `sun_cli_manifest.mli` no longer declares `render`, and its doc comment
  for the low-level builders names the actual caller.
- `test_svc_render_spec_matches_render` is removed (or replaced by a direct
  assertion on `render_spec` if it covered something no other test does).
- `dune build` and the `cli/sun` test suite pass with no remaining
  references to the deleted function.
