# AWS integration audit (`aws-eio`, `s3-eio`, `dynamodb-eio`, `lambda-eio`)

Pre-**build** audit — not pre-extraction like `obs-audit.md`/`storage-audit.md`. None of this
code exists yet; the goal here is to settle the hard design questions and name the real
blockers before writing anything, the same way `obs-extraction-plan.md` settled `obs-eio`'s
shape before implementation started.

Baseline: nothing in `sun` currently talks to AWS APIs directly. `platform/infra/aws/main.tf`
provisions EKS/VPC/ECR/RDS/Route53 + cert-manager IRSA — AWS is used today purely as a
Kubernetes cluster host, not as an application-level dependency.

**Status (2026-08-26): Layer 1 (`aws-eio`) built, reviewed, extracted, and now proven
live.** Standalone opam package at `~/Code/aws-eio` (`github.com/loganbnielsen/aws-eio`).
SigV4 signing validated against AWS's own published conformance suite (37/37 cases);
credential resolution covers Static/IRSA/Container/IMDSv2/Env_chain. Six independent
review rounds found and fixed real bugs (missing `Content-Length`, an unseeded TLS RNG,
a domain-unsafe `Lazy.t`, a signature-breaking wire/sign encoder mismatch, among
others — see the repo's `CHANGES.md`). TLS moved out to the shared `https-eio` package
(`AUDIT-` — see `docs/planning/OPAM_FOUNDATION_TRACKER.md`), compared against the
published `awskit`/`awskit-eio` family and kept on its own merits (that family lacks
IRSA support and its Eio adapter carries the same wire-byte signing risk this repo's
custom HTTP transport was built to avoid). **Proven against a live AWS endpoint
2026-08-26**: a real `STS GetCallerIdentity` call, signed by this package, accepted by
real AWS (`aws-eio`'s `test/test_aws_live.ml`, gated by `AWS_EIO_LIVE=1`, run against a
short-lived STS session token). The all-seven-package cross-pin test (Phase 3 of the
OPAM foundation tracker) also passed — no link-name clashes with `obs-eio`/`pg-eio`/
`kafka-eio`/etc. `s3-eio`, `dynamodb-eio`, and `lambda-eio` (layers 2–4 below) are next.

**Layer 2 (`s3-eio`) built 2026-08-26**: v1 scope (put/get/delete/head_object) at
`integrations/aws/s3-eio/`, committed to `sun`. Required and got a small `aws-eio` API
fix along the way — response headers were silently dropped, which `head_object`'s
entire purpose depends on (`aws-eio` commit `a6cf864`, already merged). An adversarial
review round found and fixed two real bugs: `config.bucket`/`region` spliced
unvalidated into the Host header (CRLF header-injection risk, fixed with a fail-closed
`validate_config` check) and an IPv6-endpoint parsing bug (`split_host_port` split on
the last colon, landing inside a bracketed IPv6 literal). Also documented, not
code-fixed (a real transport limitation): the local-test-server endpoint-override path
needs a real DNS-resolvable hostname and real TLS termination, since `aws-eio`'s
`signed_request` always negotiates TLS/SNI and rejects IP literals — found while
discovering this package's own tests couldn't use a lightweight local mock server at
all. Live smoke test written (`S3_EIO_LIVE=1`), not yet run against a real bucket —
live testing across all of `s3-eio`/`dynamodb-eio`/`lambda-eio` is deliberately held until
everything is built and reviewed.

**`s3-eio` extracted 2026-08-26** to a standalone package at
[github.com/loganbnielsen/s3-eio](https://github.com/loganbnielsen/s3-eio), pinned into
the switch (`git+file:///home/lbendtly/Code/s3-eio#main`). The in-tree
`integrations/aws/s3-eio/` directory is gone; `s3-eio` is now a `sun.opam` dependency
like `aws-eio` (no in-tree consumer yet, same as `aws-eio`'s own pre-consumer history).

**Layer 3 (`dynamodb-eio`) built 2026-08-26**: `Dynamodb_client` (PutItem/GetItem/
DeleteItem/Query, single-page) and the `Dynamodb_table.Index`/`Entity` typed layer at
`integrations/aws/dynamodb-eio/`. The negative-compilation guarantee (mismatched index
key = type error) was verified by hand, not via an automated dune rule — a hand-rolled
rule invoking `ocamlfind`/nested `dune build` against internal `_build` paths was
judged more likely to break than the property itself, which is a first-principles
consequence of `Index`'s functor signature rather than something that regresses
silently.

**`dynamodb-eio`'s review round found a serious cross-package bug that also silently broke
`s3-eio`, now fixed in both**: `aws-eio`'s `signed_request` already converts every
non-2xx status into `Error (Http_error (status, body))` before returning — meaning
`S3_client`/`Dynamodb_client`'s own `call` functions never actually saw a non-2xx status
arrive via `Ok`, so `interpret_*`'s entire non-2xx classification branch (the whole
reason `S3_error`/`Dynamodb_error` exist as typed error types, not just a thin `Aws_error`
passthrough) was unreachable dead code through every real `put`/`get`/`delete`/`head`/
`query` call — only ever exercised by each package's own unit tests calling
`interpret_*` directly with a synthetic status. A real 404 `GetObject` or
`ResourceNotFoundException` would have surfaced as `Error (Aws (Http_error (status,
body)))`, never the documented `Error Not_found`/`Error Resource_not_found`. Fixed in
both packages with a `reclassify_transport_result` function that re-threads
`Http_error`'s already-carried `(status, body)` back into the `Ok` shape `interpret_*`
expects, factored out as its own pure function specifically so the fix is
unit-testable without a real network call (neither package can exercise the real
wire/TLS path locally at all — see each package's test-strategy notes). Three smaller
real bugs also found and fixed in `dynamodb-eio`: `config.region` had the same
CRLF-header-injection gap `s3-eio`'s `validate_config` was built to close, not
originally carried over; `Index.get` assumed a fully-specified pk+sk always identifies
at most one item, which is only true for a table's own primary key — DynamoDB does not
enforce that uniqueness on secondary indexes, so `get` now fails loud (not silently
picks the first match) when more than one item comes back; and `Dynamodb_error.of_response`
used `Yojson.Safe.Util.member`, which raises `Type_error` on a non-2xx body that's valid
JSON but not a JSON object, crashing what's documented as a pure, always-`Result`
classifier — fixed by switching to plain `List.assoc_opt` pattern matching, which never
raises.

**`dynamodb-eio` extracted 2026-08-26** to a standalone package at
[github.com/loganbnielsen/dynamodb-eio](https://github.com/loganbnielsen/dynamodb-eio),
pinned into the switch (`git+file:///home/lbendtly/Code/dynamodb-eio#main`). The in-tree
`integrations/aws/dynamodb-eio/` directory is gone; `dynamodb-eio` is now a `sun.opam`
dependency like `aws-eio`/`s3-eio` (no in-tree consumer yet). All three of `s3-eio`,
`dynamodb-eio`, and `lambda-eio` are now extracted, matching the pattern already used for
`kafka-eio`/`obs-eio`/`pg-eio`/`aws-eio`. Remaining deferred work: live testing
(`S3_EIO_LIVE`, `DYNAMODB_EIO_LIVE`, and a Lambda RIE/live check) against real AWS
resources — not started yet.

**Layer 4 (`lambda-eio`) built 2026-08-26**: `Lambda_runtime` (the invoke-next/respond/
error loop against `AWS_LAMBDA_RUNTIME_API`, using `Cohttp_eio.Client` directly — no
`aws-eio` dependency, matching the plan, since this is unsigned local HTTP) and
`Lambda_event` (S3/SQS/DynamoDB-Streams event envelope parsing). Unlike `s3-eio`/
`dynamodb-eio`, this package's wire path genuinely runs against a real local mock server
in its own tests (plain HTTP, no TLS/SNI blocker), so its protocol correctness is tested
end to end, not just via pure-function interpretation. Two `Eio.Cancel.Cancelled`-
swallowing bugs (the same class already found in `s3-eio`/`dynamodb-eio`'s review rounds)
were caught and fixed before ever reaching a review round this time, by checking the
new code directly against the established rule. `framework/sun-fn`'s `FN` module type
changed as planned: `schedule : string` → `trigger : trigger` (`Cron of string |
Lambda`); `Make(F).run` dispatches on it, `Cron` behavior unchanged, `Lambda` loops via
`Lambda_runtime.run_loop`. The scaffold template (`sun_cli_scaffold_templates.ml`'s
`fn_lib_ml`, used by `sun new fn`) was updated to match — newly-scaffolded `-fn`
projects would otherwise fail to compile against the new signature. `sun.toml`'s
deployment-level `schedule` field (read by `sun_cli_manifest_yaml.ml`/
`sun_cli_deployment_plan.ml` to render a Kubernetes CronJob) is a separate, unrelated
layer, confirmed by reading both call sites — not touched, matching the plan's own
scoping (Lambda deploy-target rendering, i.e. actually deploying *to* Lambda instead of
a k8s CronJob, is separate, not-yet-started work). Adversarial review round found 6
findings, all real, all fixed: (1) `read_body`'s `Eio.Buf_read.parse_exn` could raise
`Failure` from inside a `match ... with resp, body -> ...` success branch — outside the
`exception` guard that only covered the preceding network call, the same class of mistake
already caught once in `dynamo_error.ml`'s `Yojson.Safe.Util` bug; fixed by moving the
body read inside the guarded match. (2/3) cancellation could fire mid-ack, abandoning an
already-completed invocation's response to the Runtime API, and `fn.ml`'s `push_metrics`
swallowed `Eio.Cancel.Cancelled` in its blanket `with exn`; fixed together — `run_loop`
now wraps the handler-and-ack sequence in `Eio.Cancel.protect` so a stop signal can only
take effect while waiting on `next_invocation`, never mid-ack, and `push_metrics` now
re-raises `Cancelled` before its catch-all. (4) if `F.run ()` raised instead of returning
`Error`, `record_and_push` was skipped, undercounting failed Lambda invocations in
metrics; fixed by catching (and converting, `Cancelled` excepted) inside the handler
closure before recording. (5) `next_invocation` didn't check the invocation/next
response's HTTP status, relying only on incidental header presence; fixed to reject
non-2xx explicitly. (6) `init_error` had zero callers — real, but there's no actual
sun-fn init step between obtaining `base` and entering `run_loop` to wire it to yet, so
left as documented, tested (new regression test added), generically-useful Runtime API
surface for other callers rather than forcing one. Full test suite: 9 lambda_runtime + 8
sun-fn, all passing.

**`lambda-eio` extracted 2026-08-26** to a standalone package at
[github.com/loganbnielsen/lambda-eio](https://github.com/loganbnielsen/lambda-eio),
pinned into the switch (`git+file:///home/lbendtly/Code/lambda-eio#main`), matching the
extraction pattern already used for `kafka-eio`/`obs-eio`/`pg-eio`/`aws-eio`. The in-tree
`integrations/aws/lambda-eio/` directory is gone; `sun-fn`'s `lib/dune` now depends on it
as `lambda-eio` (the external package's public name) instead of the in-tree `lambda_eio`
module name.

**`lambda-eio` deployment proven 2026-08-27** (still short of a real AWS deployment):
`examples/echo-lambda/` in the `lambda-eio` repo packages `test/rie_echo_handler.exe` as
a container image and verifies it with AWS's own documented local-testing recipe for
container-image Lambda functions (`aws-lambda-rie` mounted in as the entrypoint,
wrapping our `bootstrap`) — two invocations against the same warm container, matching
real Lambda's init/invoke/reuse lifecycle. Container images were chosen over zip-based
custom runtimes specifically to avoid a real portability risk: a `bootstrap` binary
built on a typical dev machine's glibc (2.39 here) fails to even start on Amazon Linux's
older glibc, which is forward-compatible only; both Dockerfile stages share the same
`ubuntu:24.04` tag, so the binary always runs against the glibc it was built against.
Wired into CI as a new required check (`echo-lambda-container`), credential-free. The
exact remaining real-AWS steps (ECR push, IAM trust/execution policy, `create-function`,
`invoke`) are documented in `examples/echo-lambda/README.md` but not yet run for real —
that's part of the same live-testing work still waiting on AWS credentials, alongside
`s3-eio`/`dynamodb-eio`'s live tests.

## Short version

Four packages, following the same layering `obs-eio`/`obs-loki-eio`/`obs-prometheus-eio`
established:

```text
        s3-eio          dynamodb-eio          lambda-eio
           \                |                    |
            \_______________|                    |
                    aws-eio                  (no dependency on aws-eio —
              (auth, SigV4, HTTP)          Lambda's Runtime API is a local,
                                            unsigned sidecar call, not a
                                            signed AWS API call)
```

Unlike `pg-eio`, this is genuinely new protocol work: OCaml's existing AWS clients
(`aws-s3`, `ocaml-aws`) are Lwt/Async, not Eio, so there is no `caqti-eio`-equivalent to lean
on. This is shaped like the original `kafka-eio` effort, not the `pg-eio` one — real FFI-free
protocol work (HTTP + SigV4 + JSON/XML), not a thin policy wrapper over an existing Eio driver.

The HTTP/TLS plumbing is not new work, though: every existing outbound-HTTPS caller in this
repo (`kafka_service_tls.ml`, `obs_loki.ml`) already uses the same stack —
`Tls_eio` + `X509`/`Domain_name`/`Ptime` for the CA bundle, `Cohttp_eio.Client` for the call.
`aws-eio` reuses that pattern directly; no new HTTP library.

Crypto is already available in the switch (transitively, via `tls-eio`): `digestif` (SHA256 +
HMAC-SHA256 — everything SigV4 needs) and `hex`/`ohex` for signature encoding. Neither needs
`opam install`, just declaring as direct dependencies. `yojson` is already a direct `sun`
dependency (DynamoDB's wire protocol is JSON). S3's XML-based operations (list-objects,
multipart) would need a genuinely new dependency — `xmlm` or `ezxmlm` — not currently
installed anywhere in the switch. `PutObject`/`GetObject`/`DeleteObject` themselves don't need
XML, so this can be deferred past a v1 that covers just those three.

## Layer 1: `aws-eio` — credentials, SigV4, HTTP transport

### Credential resolution

The design draft this audit followed up on proposed env vars → container credentials → IMDSv2.
That's incomplete for this repo specifically: `platform/infra/aws/main.tf` already provisions
EKS with **IRSA** (IAM Roles for Service Accounts) for cert-manager, and Sun's own workloads
deploy as EKS pods, not raw EC2 instances. A Sun service running in its actual target
environment authenticates via the **`AssumeRoleWithWebIdentity`** flow
(`AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE`, a Kubernetes-projected service-account
token exchanged with STS) — not IMDSv2. Missing IRSA from the credential chain means the
happy path for Sun's own deployment target doesn't work. Resolution order should be:

1. Static env vars (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`) — dev/test.
2. IRSA web identity token (`AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE`) — EKS production path.
3. ECS/Fargate container credentials (`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`).
4. EC2 IMDSv2 — last resort, mainly for local `sun dev up` parity or non-EKS deploys.

**This needs the same "Security on Day 1" treatment `Kafka_security.t` gets** — both
`README.md` and `.claude/CLAUDE.md` state this as a repo-wide principle, not something
optional to bolt on later. Concretely: an `Aws_credentials.t` type that is a **required**
field on every `s3-eio`/`dynamodb-eio` config record, with a variant per source
(`Static of {access_key; secret_key; session_token}` | `Web_identity of {role_arn; token_path}`
| `Container` | `Imdsv2` | `Env_chain` — an explicit "try them in order" option, not a
silent default), the same way `Kafka_security.t` forces every environment to state its
posture instead of inferring it. `Env_chain` should still exist for dev convenience, but
picking it should be a visible choice in the config, not what happens when the field is
just absent.

IMDSv2 specifically needs a bounded hop limit and short timeout on the token-fetch request —
treat it as untrusted-network-adjacent (SSRF-shaped risk if a URL ever became attacker
-influenced) even though in practice the endpoint is fixed (`169.254.169.254`).

### SigV4 signer

Canonical request construction (sorted/trimmed headers, URI path normalization, query-string
encoding per AWS's specific rules) is the classic source of subtle from-scratch SigV4 bugs —
this should be rated **Medium** risk, not the "Low" a first draft of this scoping suggested.
Two concrete asks before this is considered done, not just "tests pass":

- Validate against AWS's own published SigV4 test suite (canonical request / string-to-sign /
  derived signing key / final signature fixtures), the same way `obs-eio-prometheus`'s text
  exposition format was checked against the real Prometheus grammar, not just hand-rolled
  assertions.
- Handle the signing-key date boundary explicitly (a request signed at 23:59:59 UTC uses a
  different day's derived key than one at 00:00:01) and AWS's ±15 minute clock-skew rejection
  window — both are real, previously-seen sources of "works in dev, fails in prod at a
  specific time of day" bugs in from-scratch SigV4 implementations elsewhere.

Support both the header-based signing S3/DynamoDB calls need and streaming
`UNSIGNED-PAYLOAD` mode for large S3 uploads (avoids buffering the whole body to compute its
SHA256 up front). `UNSIGNED-PAYLOAD` trades payload-integrity-via-signature for TLS-only
integrity — document that trade explicitly in the `.mli`, the same way `obs-loki-eio`
documents its span-close-timestamp semantics instead of leaving the behavior implicit.

### HTTP transport

`Cohttp_eio.Client` + `Tls_eio`, matching every existing caller — no `h2`/`httpaf`
alternative; there's no precedent for that stack anywhere in this repo and no reason to
introduce a second one.

**Retry/backoff is not optional for this layer.** DynamoDB throttles
(`ProvisionedThroughputExceededException`) and both DynamoDB and S3 return retryable 5xxs
under normal operation — an AWS client without exponential backoff + jitter will misbehave
under any real load. This belongs in `aws-eio`'s transport so `s3-eio`/`dynamodb-eio` get it
for free, not reimplemented per backend.

### Error type

`Aws_error.t` — shared base (`Http_error of int * string`, `Signature_error of string`,
`Network_error of string`, `Credential_error of string`) that `s3-eio`/`dynamodb-eio` extend
with service-specific variants, the same relationship `kafka-eio-service` has to
`Kafka_error.t`. Neither of the design drafts this audit is responding to actually defined
this type — `Dynamodb_eio.error` was referenced but never specified. Every public API returns
`(_, Aws_error.t)` (or an extension) `result`. Never raise — this repo has zero exceptions
escaping a storage/Kafka layer today (`docs/audits/AUDIT.md`), and an AWS layer is no
exception to that rule literally.

## Layer 2: `s3-eio`

Streaming `Eio.Flow.source`/`Eio.Flow.sink` for `put_object`/`get_object` is the right call —
avoids buffering large objects in memory. The one correction from the first design draft:
every operation returns `(_, S3_error.t) result`, not bare `unit`/`'a`. A raising or
unit-returning S3 client is the one thing this repo's own conventions rule out outright.

v1 scope: `put_object`, `get_object`, `delete_object`, `head_object` — all four have simple
REST-with-headers signing, no XML. `list_objects_v2` (XML response) and multipart upload
(session state across several signed requests) are real additional scope — defer past v1,
track as a follow-up rather than silently expanding this package's first cut.

## Layer 3: `dynamodb-eio` — the ElectroDB-replacement layer

This is the part worth getting right before writing any code — it's the actual value
proposition, not a thin client wrapper, so it ships once, correctly, rather than as a
low-level client now and a "real" typed layer later.

### What ElectroDB actually gets wrong (for the record)

1. Composite keys assembled from runtime template strings (`` `USER#${id}` ``) — a missing
   or reordered parameter is a runtime bug, sometimes a silent one (wrong partition, not an
   error).
   2. Querying an index with a key shape that doesn't match its actual schema is a runtime
   failure (or worse, silently wrong results), not a compile error.
3. Multiple entity types sharing one physical table need a manual discriminator attribute to
   avoid collisions, easy to forget on a new entity.

### The fix — and it does not need GADTs

Two design drafts fed into this audit both invoked "GADTs" but neither's sample code actually
used one — both still had `format_pk : pk -> string`, which is the same string-templating
footgun ElectroDB has, just relocated. The mechanism that actually delivers "wrong index is a
type error, not a runtime bug" is simpler and more idiomatic than GADTs: **one module per
index, each with its own nominally distinct `pk`/`sk` types, each generating its own typed
`get`/`query` functions via a functor** — exactly `pg-eio`'s `Table.Make(SCHEMA)` pattern,
applied once per index instead of once per table.

```ocaml
(* Each entity declares its primary index and every GSI as its own SCHEMA-shaped module.
   pk/sk are real sum types, not strings — a typo'd variant doesn't compile; a missing
   case in a match is a warning/error, not a silent no-op. *)
module type INDEX = sig
  type pk
  type sk

  val index_name : string option   (* None = table's primary index *)
  val format_pk  : pk -> string
  val format_sk  : sk -> string
end

module User_primary : INDEX with type pk = [ `Org of string ]
                              and type sk = [ `User of string ] = struct
  type pk = [ `Org of string ]
  type sk = [ `User of string ]
  let index_name = None
  let format_pk (`Org id) = "ORG#" ^ id
  let format_sk (`User id) = "USER#" ^ id
end

module User_by_email : INDEX with type pk = [ `Email of string ]
                               and type sk = [ `Metadata ] = struct
  type pk = [ `Email of string ]
  type sk = [ `Metadata ]
  let index_name = Some "gsi1"
  let format_pk (`Email e) = "EMAIL#" ^ e
  let format_sk `Metadata = "METADATA"
end

(* Table.Index(I) generates get/query typed against I.pk/I.sk specifically — there is no
   function anywhere that accepts "any index's key". Passing User_by_email's `Email pk to
   a query built from Table.Index(User_primary) is a type error: [ `Org of string ] and
   [ `Email of string ] don't unify. That's the actual guarantee ElectroDB can't offer. *)
module Primary = Dynamodb_eio.Table.Index(User_primary)
module ByEmail = Dynamodb_eio.Table.Index(User_by_email)

let _ = Primary.get      client ~pk:(`Org "org_9") ~sk:(`User "usr_1")
let _ = ByEmail.query    client ~pk:(`Email "a@example.com") ()
(* let _ = Primary.get client ~pk:(`Email "x") ~sk:... -- does not compile *)
```

Entity discrimination (ElectroDB's `__edb_e__`) becomes a required, typed field the
functor injects on `put` and checks on decode — `Table.Entity(E)` stamps `E.name` into a
reserved attribute and `of_item` rejects an item whose stamped name doesn't match, returning
`Aws_error`-shaped `Wrong_entity of string` rather than silently decoding garbage into the
wrong OCaml type. This should be non-optional, not a feature callers can forget to wire up —
the exact "forgetting the discriminator" case ElectroDB requires you to set up by hand.

### Package boundary

Keep this **inside** `dynamodb-eio`, not a separate `sun-electro`/`dynamo-electro` package.
`pg-eio` didn't split its low-level `Db` module from `Table.Make` into two packages, and this
layer is dynamodb-eio's whole reason to exist here rather than someone just reaching for
`ocaml-aws`'s DynamoDB bindings directly (once those get an Eio-compatible fork, which they
don't have today). One package, `Dynamodb_eio.Table.Index(...)` living alongside a lower-level
`Dynamodb_eio.Client` for callers who want raw `PutItem`/`Query`/`UpdateItem` access.

### Open design gaps, not yet resolved by this audit

- **Conditional writes / optimistic locking** — DynamoDB's `ConditionExpression` is how you
  get compare-and-swap semantics; ElectroDB exposes this loosely-typed. Worth a typed
  equivalent, not scoped here — flag as a v2 item, don't let it block v1's `put`/`get`/`query`.
- **Update expressions** (`SET`/`REMOVE`/`ADD` attribute-path syntax) — real design work,
  deferred past v1 the same way `pg-eio`'s `sun-storage.md` explicitly deferred
  update/upsert helpers. `put` (full-item replace) covers v1.
- **Pagination** (`LastEvaluatedKey`) — needs a typed cursor, not a raw opaque map, to avoid
  ElectroDB's own pagination footguns (a cursor silently valid for the wrong index/query).

## Layer 4: `lambda-eio`

### Split, matching the kafka-eio-core / kafka-eio-service precedent

- **`lambda-eio`** (extractable, generic): the Lambda Runtime API long-poll loop
  (`GET .../invocation/next` → run handler → `POST .../response` or `.../error`), event-JSON
  parsing helpers for common trigger shapes (S3, SQS, DynamoDB Streams event envelopes). No
  dependency on `aws-eio` — the Runtime API is a local, unsigned HTTP sidecar
  (`AWS_LAMBDA_RUNTIME_API` env var points at a loopback address Lambda's execution
  environment provides), not a signed AWS API call. Confirmed no repo precedent conflicts with
  giving this its own package.
- **Sun-specific glue** (stays in-tree, `integrations/aws/` or directly in `framework/sun-fn/`):
  extends `sun-fn`'s `FN` module type to support a Lambda trigger. Confirmed by reading
  `framework/sun-fn/lib/fn.ml`/`.mli`: `schedule : string` is the *only* cron-specific field
  in the whole module; signal handling, metrics registration, Pushgateway push, and exit-code
  mapping are already generic "run once, report status" logic with zero cron awareness. This
  is a smaller change than either design draft assumed — no parallel `Sun.Lambda`/`Sun.Server`
  API, no env-var-sniffing dispatcher (inconsistent with this repo's explicit-over-implicit
  posture). Concretely: `FN`'s `schedule : string` becomes a `trigger` variant
  (`Cron of string | Lambda`), and `Make(F : FN)`'s `run` dispatches on it — same functor,
  same call site, no new top-level API surface.
- **Scope, per this session's decision**: `-fn` only for v1. Lambda fronting `-svc` over API
  Gateway is a different integration point (HTTP request/response cycle, not "run once and
  exit") and explicitly out of scope for this pass.
- Deploy-target rendering: `cli/sun/lib/sun_cli_deployment_plan.ml`'s `render_workload`
  variant (`Render_svc | Render_worker | Render_fn`) is a *workload-shape* dimension only —
  it always emits k8s YAML. Lambda needs a second, orthogonal *target* dimension (k8s YAML vs.
  Terraform/SAM), not a fourth `render_workload` case. No Terraform Lambda/IAM/API-Gateway
  resources exist anywhere in `platform/infra/aws/` today — this is new ground, not extending
  something partially started.

## Package shape

```text
integrations/aws/
  aws-eio/            lib/, test/, aws-eio.md      -- credentials, SigV4, HTTP transport, Aws_error
  s3-eio/              lib/, test/, s3-eio.md        -- put/get/delete/head_object
  dynamodb-eio/          lib/, test/, dynamodb-eio.md    -- Client + Table.Index/Table.Entity
  lambda-eio/          lib/, test/, lambda-eio.md    -- generic Runtime API loop, event parsing
```

Matches the confirmed layout convention (`integrations/<domain>/<package-name>/{lib,test}` +
`<package-name>.md`) from `integrations/kafka/kafka-eio-service/` and pre-extraction
`integrations/storage/sun-storage/`. `-fn`'s trigger-variant change lives in
`framework/sun-fn/` directly, not under `integrations/aws/` — it's Sun policy, same as
`kafka-eio-service`.

Recommended OPAM names when/if these follow `kafka-eio`/`obs-eio`/`pg-eio` out to standalone
repos: `aws-eio`, `s3-eio`, `dynamodb-eio`, `lambda-eio` — no naming ambiguity like `pg-eio` had
(`obs-eio-loki` → `obs-loki-eio`), these are new packages with no prior in-tree name to diverge
from.

## Test checklist before any of this is considered done

- [ ] SigV4 signer validated against AWS's published test suite (canonical request /
      string-to-sign / signature fixtures), not just hand-rolled assertions.
- [ ] Credential chain covers IRSA web-identity (Sun's actual EKS deployment path), not just
      static keys + IMDSv2.
- [ ] Every public API returns `(_, Aws_error.t)`-or-extension `result`; nothing raises.
- [ ] Retry/backoff with jitter exists in `aws-eio`'s transport, exercised by a test that
      forces a throttling response.
- [ ] `Dynamodb_eio.Table.Index(WrongIndex).get` with another index's key type fails to
      *compile* — this is the one test that has to be a `dune` negative-compilation check
      (or equivalent), not a runtime assertion, since compile-time rejection is the entire
      point of the design.
- [ ] Entity discriminator mismatch on decode returns a typed error, tested explicitly.
- [ ] Live tests (against real S3/DynamoDB/a local Lambda Runtime API stub) gated by env vars,
      matching every existing integration test in this repo.

## What not to do

- Don't add `h2`/`httpaf` or any HTTP stack beyond `cohttp-eio` — no precedent, no need.
- Don't ship `dynamodb-eio` as a low-level client first and the typed modeling layer later —
  the modeling layer is why this package exists over reaching for a generic DynamoDB binding.
- Don't build S3's XML-based operations (`list_objects_v2`, multipart) in v1 — REST-with-
  headers-only operations first, XML parsing is separate, real scope.
- Don't build Lambda support for `-svc` in this pass — `-fn` only, per this session's decision.
- Don't let credential resolution default silently to "try everything" — `Env_chain` should
  be a value someone chose, not what happens when the field is empty.

## Recommended order

1. `aws-eio`: credentials (incl. IRSA) + SigV4 signer, validated against AWS's test vectors,
   before either backend is written.
2. `s3-eio`: the four REST-only operations, proves the transport layer end-to-end against a
   real bucket.
3. `dynamodb-eio`: `Client` (raw `PutItem`/`GetItem`/`Query`) first, then `Table.Index`/
   `Table.Entity` on top — the hard part is the typed layer, get the wire protocol working
   first so the typed layer has something real underneath it.
4. `lambda-eio`: Runtime API loop (generic, no dependency on the other three) + `sun-fn`'s
   trigger-variant change, in parallel with 1–3 since it doesn't depend on them.
