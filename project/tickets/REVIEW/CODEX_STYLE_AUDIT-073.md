---
id: CODEX_STYLE_AUDIT-073
type: refactor
severity: medium
source: docs/audits/STYLE_AUDIT.md
branch: CODEX_STYLE_AUDIT-073/explicit-config-parse
worktree: ../sun-CODEX_STYLE_AUDIT-073-explicit-config-parse
---

Replace silent defaulting in CI/CD-facing configuration with explicit parse results.

**Depends on:** none.

**Problem:** Several CI/CD-facing parsers convert unknown or missing external
values into defaults, for example environment/mode parsing, secret env parsing,
Kafka security protocol parsing, and deployment rollout strings. In infra code,
silent defaults reduce trust because typos can become real cluster changes.

**Goal:** Establish a repository-wide rule that external config parsing returns
typed `Result` values and unknown values fail closed.

**Acceptance criteria:**

- Add a short policy to `docs/audits/STYLE_AUDIT.md` or architecture docs.
- Convert high-risk mode/backend/security parsers first.
- Add tests showing unknown values produce errors rather than defaulting.
- Keep intentional defaults only for omitted values with documented defaults.
