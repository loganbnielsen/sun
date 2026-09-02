---
description: Self-review checklist to run against your own diff before pushing or updating a PR, so an external reviewer finds fewer (ideally zero) issues. Use before `sundev pipeline submit`, before pushing a follow-up commit to an open PR, or whenever asked to review your own work.
---

# /self-review - Catch your own bugs before a reviewer does

Run this against your own diff (`git diff main...HEAD` in the worktree)
before submitting or pushing a follow-up. Each item below came from a real
finding an external reviewer had to catch first. Go through the list against
the actual diff — don't just skim and assume it's fine.

## 1. Status/health semantics

- Does "empty" or "absent" default to healthy? Check explicitly — a
  resource that was never created is not the same as one that's running
  fine, and both can look like "no problems found" if you're not careful.
- Split "confirmed absent/failed" from "couldn't check" (transient error,
  parse failure) at every I/O boundary feeding a health decision. Collapsing
  both into the same `None`/default hides real failures as silence.
- If a resource can have several historical instances (retained Job/pod
  history, old completed runs), don't reconstruct "current state" by
  scanning the list — use the parent resource's own status field if one
  exists (e.g. a CronJob's `status.lastSuccessfulTime`, not its pods).
- If a diagnosis only covers part of the lifecycle (e.g. last *completed*
  run, not an in-progress one), say so explicitly in the doc comment
  instead of implying full coverage.

## 2. Comparisons and parsing

- Never compare timestamps as raw strings — formats can mix (fractional
  vs. whole seconds), and lexical order isn't chronological order. Parse
  with the real type (`Ptime.of_rfc3339`, etc.) and compare parsed values.
- When a parse can fail, fail toward *surfacing* a finding, not silently
  treating it as OK.

## 3. Public API surface (`.mli`)

- For every new `val` in a `.mli`, grep `bin/` and `test/` for an actual
  external caller. If nothing outside the module calls it directly, don't
  expose it — keep it a private `let` in the `.ml`.
- Don't duplicate long doc comments between `.ml` and `.mli`. The `.mli` is
  canonical; the `.ml` gets at most a one-line pointer.

## 4. Types over booleans

- A parameter that picks between two (or more) named behaviors should be a
  variant, not a `bool`. `Continuous | Ephemeral` beats
  `~expects_continuous_pods:bool`.
- If the correct behavior depends entirely on the caller picking the right
  case, make the parameter required, not defaulted — a silent default can
  mask a caller applying the wrong model.

## 5. Comments and commit hygiene

- No "round N review" / review-history narrative in source or test files.
  That belongs in commit messages and PR descriptions, never in code.
- Comments explain WHY (a non-obvious constraint or invariant), never WHAT
  the code already says via naming.

## 6. Before claiming a fix is live

- Run `git status --short` after editing+testing, *before* doing anything
  else (merging, rebasing) — an uncommitted fix can get silently carried
  through a `git merge` and never actually reach the remote.
- After pushing, verify with `gh pr diff <N>` (the actual remote content),
  not just local `git log`/`git status`, before telling anyone a finding is
  fixed.
- Before agreeing a reviewer's "file deleted"/"hygiene" claim is real,
  check `gh pr view <N> --json mergeable,mergeStateStatus`. `BEHIND` means
  the branch is missing later `main` commits, which makes a raw diff show
  main-only additions as if the PR deleted them. Fix by merging `main` into
  the branch, not by explaining away the finding.

## 7. Test coverage

- Every new behavioral branch — especially one added to fix a specific
  bug — needs a test that fails without the fix, not just a happy-path
  test that still passes either way.
- When a function's contract changes (new required param, split return
  type), update every existing test to the new shape; don't leave stale
  callers passing by accident.

## 8. Scope discipline

- If fixing one bug surfaces an adjacent, genuinely separate gap, name the
  boundary explicitly in the docs/comments and file a new ticket for it —
  don't silently expand the current PR, and don't silently ignore the gap
  either.

## 9. Git/PR workflow

- Never merge your own PR (`gh pr merge` / `gh api .../merge`). Open it and
  stop.
- If a PR is still open, push a follow-up commit to its branch. Only open a
  new PR for genuinely separate work, or once the prior PR is merged.
