---
id: REFAC-067
type: refactor
severity: high
source: cross-cutting-design-review 2026-08-31
---

Hide test-only internals from `sun-svc` and `sun-worker` public surfaces

**Depends on:** REFAC-066.

## Problem

`sun-svc` and `sun-worker` still expose internals because tests call them
directly: `Route.match_path`, `Route.method_of_http`, `Auth.validate`,
`Auth.fetch_jwks_over_https`, and `Worker.?test_consume_loop`.

## Goal

Keep flat vendored-module ergonomics, but stop advertising internal/test seams
as normal user-facing API.

## Acceptance criteria

- Internal route/auth helpers move behind a private or clearly internal module.
- Worker test injection is not part of the normal public runner signature.
- Existing routing/auth/worker tests still exercise the same production logic.
- No wrapped-facade rewrite for the `*-eio` packages.
