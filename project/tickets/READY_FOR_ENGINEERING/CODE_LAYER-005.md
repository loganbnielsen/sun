---
id: CODE_LAYER-005
type: bug
severity: high
source: project/audits/2026-09-06_code_layer_audit.md
---

**Depends on:** None.

## Problem

`cmd_dev.ml` (`sun dev up`, local k3d) and `platform/infra/base/main.tf`
(Terraform, applied to real EKS/GKE clusters) each hand-maintain a second,
fully independent set of Helm `chart`/`version`/`values` for every platform
component they both install — Redpanda, PostgreSQL, Loki, Grafana, Alloy,
Tempo, Prometheus. The only thing keeping the two in sync today is a code
comment repeated across both files ("Dev mirrors prod exactly"); there is no
shared file, generator, or test that enforces it mechanically.

This has already produced a real, filed bug: BUG-013 fixed Loki's
`commonConfig.replication_factor` in `platform/infra/base/main.tf` only.
Nobody thought to check `cmd_dev.ml`'s independent Loki `helm_install` call,
so it still lacks the fix (BUG-016). CODE_LAYER-006, CODE_LAYER-007, and
CODE_LAYER-008 are three more concrete instances of this exact same failure
mode (Alloy config, Grafana dashboard JSON, and chart-version/value drift),
found by doing for every other shared chart what BUG-016 did for Loki.

## Goal

Give `cmd_dev.ml` and `platform/infra/base/main.tf` one shared, versioned
description of what each Sun platform component needs — chart name, pinned
version, and the value overrides for the single-replica/local profile — so
that a value or version change is one edit, not a "remember to also update
the other file" convention that has already been missed once.

## Remediation

OCaml and HCL can't share source directly, but they can share data. Add a
per-chart spec file under `platform/infra/base/charts/` (YAML or JSON: chart
name, pinned version, and the common/local-profile value overrides) that:

- `platform/infra/base/main.tf` reads via `yamldecode(file(...))` in place of
  today's hand-typed `helm_release` blocks (env-specific values like
  `self_hosted_durable`'s S3 backing still come from `main.tf` variables —
  the shared file only owns what dev and prod genuinely share).
- `cmd_dev.ml` reads the same file (via existing Yojson/toml plumbing) to
  drive its `Sun_cli_helm.upgrade_install` calls, instead of the current
  inline OCaml value lists.

This is a structural fix; land CODE_LAYER-008's immediate version-pin/value
reconciliation first if that's faster to ship, then fold those pinned
values into the shared spec file as part of this ticket so the two files
stop drifting going forward.

## Acceptance criteria

- A single file (or small set of per-chart files) under
  `platform/infra/base/` is the source of truth for chart name, version, and
  shared values for Redpanda, PostgreSQL, Loki, Grafana, Alloy, Tempo, and
  Prometheus.
- `platform/infra/base/main.tf`'s `helm_release` resources read from that
  source instead of hand-typed literals for the values it now shares with
  dev.
- `cmd_dev.ml`'s `helm_install` calls read from the same source instead of
  hand-typed OCaml value lists.
- A fresh `sun dev down --cluster && sun dev up` produces the same chart
  versions and shared values `platform/infra/base/main.tf` would apply for
  the equivalent local profile.
- Focused tests pass for the `cli/sun` package; a full `sun dev up` cycle is
  verified manually since Helm/k3d integration isn't exercised by unit tests.
