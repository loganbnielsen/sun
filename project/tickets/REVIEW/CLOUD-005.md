---
id: CLOUD-005
type: feature
severity: high
source: docs/planning/POST_DOGFOOD_GAMEPLAN.md
branch: CLOUD-005/hosted-builder-registry-handoff
worktree: ../sun-CLOUD-005-hosted-builder-registry-handoff
---

Add a real hosted builder and registry handoff path.

**Depends on:** CLOUD-004.

**Problem:** `sun cloud deploy` has a release model and logs, but the hosted
deploy path does not yet build an image, push it to a registry, and hand that
image to the runtime deployment path. Without that handoff, hosted deploys are
still contract tests rather than usable product behavior.

**Goal:** Turn the hosted deploy flow into a real build-and-publish pipeline
that records the produced image digest in the release model.

**Remediation:**

1. Define the hosted build interface around workspace path, project ID,
   environment, git/ref metadata, and build context.
2. Implement a local builder adapter that can build the generated workspace
   image using the existing container tooling.
3. Push the built image to a configured registry and capture the digest.
4. Store image tag and digest on the hosted release record.
5. Feed the image reference into the existing hosted deployment path.
6. Stream build and push log lines through the hosted release log model.
7. Add tests with a fake builder/registry adapter and one integration path that
   exercises the real command wiring when local container tooling is available.

**Acceptance criteria:**

- A hosted deploy records a non-empty image tag and digest.
- Release logs include build, push, and deploy phases.
- Failed builds produce failed release records with useful logs.
- The builder/registry boundary is injectable for tests.
- Existing cloud deploy API and CLI contracts continue to work.

**Out of scope:**

- Remote build farm scheduling.
- Multi-architecture builds.
- Custom domains or TLS provisioning.
