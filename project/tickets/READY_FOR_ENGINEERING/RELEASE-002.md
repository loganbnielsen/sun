---
id: RELEASE-002
type: verification
severity: high
source: docs/planning/POST_DOGFOOD_GAMEPLAN.md
---

Smoke-test the published alpha release artifact as a clean release user.

**Depends on:** RELEASE-001.

**Problem:** A release asset can exist while still depending on contributor
state, stale documentation, or an accidental source checkout. After publishing
the post-hardening alpha, an engineer needs to verify the public path from a
clean directory and record any mismatch.

**Goal:** Prove that `v0.1.0-alpha.5` works without cloning the Sun repository
or setting `SUN_HOME`.

**Remediation:**

1. Create a clean temp directory outside the repository.
2. Download and unpack the published tarball:

   ```bash
   curl -fL -o sun-v0.1.0-alpha.5-linux-x86_64.tar.gz \
     https://github.com/loganbnielsen/sun/releases/download/v0.1.0-alpha.5/sun-v0.1.0-alpha.5-linux-x86_64.tar.gz
   tar xzf sun-v0.1.0-alpha.5-linux-x86_64.tar.gz
   export PATH="$PWD/sun-v0.1.0-alpha.5-linux-x86_64/bin:$PATH"
   ```

3. Verify the binary and scaffold path:

   ```bash
   sun --help
   sun new workspace alpha_release
   cd alpha_release
   dune build
   ```

4. Run the local product loop:

   ```bash
   sun dev up
   sun up
   sun migrate --table alpha_release_migrations
   sun status
   sun logs payments/charge_svc --no-follow --tail=50
   ```

5. Exercise the generated app:

   ```bash
   curl -sf http://localhost:8080/health
   curl -sf -X POST http://localhost:8080/charges \
     -H 'Content-Type: application/json' \
     -d '{"customer_id":"cus_alpha","amount_cents":777,"currency":"usd"}'
   curl -sf http://localhost:8080/notifications
   ```

6. Verify release-review and GitOps artifacts:

   ```bash
   sun deploy --dry-run --emit-plan-to /tmp/alpha-release-plan.json
   sun deploy --emit-to /tmp/alpha-release-gitops \
     --secret-backend external-secrets \
     --secret-store-ref alpha-store \
     --secret-remote-prefix /alpha/release
   grep -q '"topics":' /tmp/alpha-release-plan.json
   grep -q '"migrations":' /tmp/alpha-release-plan.json
   grep -R "kind: ExternalSecret" /tmp/alpha-release-gitops
   ! grep -R 'stringData:.*".\\+"' /tmp/alpha-release-gitops
   ```

7. Record the smoke-test transcript and findings in
   `project/dogfood/RELEASE_002_<YYYY-MM-DD>.md`.

**Acceptance criteria:**

- The tarball install works without `SUN_HOME` or a source checkout.
- The generated workspace builds.
- Local substrate, deploy, migrate, status, logs, and app requests work.
- Plan JSON includes topics and migrations.
- GitOps output uses ExternalSecret resources and contains no secret values.
- Any failure or workaround is captured as a follow-up ticket.
