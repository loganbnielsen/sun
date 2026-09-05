(* ── Shared templates ─────────────────────────────────────────────────────── *)

let tpl_ocamlformat = {tpl|profile = default
version = 0.27.0
|tpl}

let tpl_dune_project = {tpl|(lang dune 3.0)
|tpl}

let tpl_readme = {tpl|# {{Name}}

A Sun workspace with two services: `charge_svc` (HTTP) and `notify_worker` (Kafka consumer).

## Prerequisites

System packages required before building:

```bash
sudo apt-get install -y librdkafka-dev libpq-dev libpq5
```

`vendor/framework` and `vendor/integrations` are symlinks into the Sun source tree.
`sun new workspace` creates them automatically.

- **Release tarball install:** The bundle includes framework source — no extra steps needed.
- **Source checkout install:** Set `SUN_HOME` once (in `~/.bashrc` or `~/.zshrc`), then
  `sun new workspace` creates the links automatically.
  If you cloned the repo but the symlinks are missing:
  ```bash
  export SUN_HOME=/path/to/sun
  ln -sf $SUN_HOME/framework vendor/framework
  ln -sf $SUN_HOME/integrations vendor/integrations
  ```

## Build

```bash
eval $(opam env)
dune build
```

## Run locally

```bash
sun dev up      # provision local k3d cluster + Kafka + supporting infra (~5 min first run)
sun dev run     # build images and run all services against local infra
```

## Deploy to cluster

```bash
sun up          # build images and deploy to cluster
sun status      # show running pods and endpoints
sun migrate     # apply database migrations
sun rollback    # roll back all services to previous image
```

## Project layout

```
events/payments/          ← Charged event contract (payments team owns)
app/payments/charge_svc/  ← HTTP service (publishes Charged on POST /charges)
app/comms/notify_worker/  ← Kafka consumer (subscribes to Charged)
lib/                      ← shared storage module (used by svc and worker)
db/migrations/            ← SQL migration files
  *.sql                   ← forward migrations
  *.down.sql              ← rollback migrations (used by `sun migrate rollback`)
test/                     ← schema backward-compatibility CI gate
  test_schemas.ml
  dune
.dockerignore             ← excludes _build/ and .git/ from Docker build context
vendor/                   ← symlinks to Sun framework source (not committed)
```
|tpl}

let tpl_sun_toml = {tpl|# Sun service configuration — all fields are optional.

[infra.scale]
# replicas = 1
# cpu      = "250m"
# memory   = "256Mi"

[infra.env]
# secrets = []
# config  = {}

[infra.rollout]
# strategy = "canary"       # or "blue-green"
# steps    = [10, 40, 100]  # canary only
|tpl}

(* -fn sun.toml: [service] carries the cron schedule so sun deploy reads it
   without scanning OCaml source for "schedule = ..." string literals. *)
let tpl_fn_sun_toml = {tpl|# Sun service configuration — all fields are optional.

[service]
schedule = "0 * * * *"   # cron schedule (default: every hour)

[infra.scale]
# cpu    = "100m"
# memory = "128Mi"

[infra.env]
# secrets = []
# config  = {}
|tpl}

(* Event-directory sun.toml: [service] carries the topic name so sun deploy
   discovers topics without scanning OCaml source. *)
let tpl_event_sun_toml = {tpl|# Sun event metadata.

[service]
topics = ["{{team}}-{{name}}s"]
|tpl}

(* Three-job pipeline: build-and-test, build-images, deploy — see the
   generated workflow's own header comment for the full contract. *)
let tpl_github_ci = {tpl|# Sun CI - build, test, and deploy on every push to main.
#
# Required GitHub secrets (Settings -> Secrets and variables -> Actions):
#   REGISTRY           container registry prefix, e.g.:
#                        AWS ECR:   123456789.dkr.ecr.us-east-1.amazonaws.com
#                        GCP AR:    us-central1-docker.pkg.dev/my-project/{{name}}
#                        Docker Hub: docker.io/myorg
#   REGISTRY_USER      registry username (or "AWS" for ECR)
#   REGISTRY_PASSWORD  registry password / access token
#
# Required GitHub repo variable (Settings -> Secrets and variables -> Actions ->
# Variables -- not a secret, this is just a path):
#   SUN_TARGET         deployment target, <env>/<provider>/<region>, e.g.
#                      prod/aws/us-east-1. Requires a matching
#                      sun/<env>/<provider>/<region>.yml file committed in
#                      this repo -- this workspace ships a placeholder at
#                      sun/prod/aws/us-east-1.yml; rename it to match your
#                      real target if it isn't prod/aws/us-east-1.
#
# Optional (GitOps push step):
#   GITOPS_TOKEN       GitHub token with repo-write access to commit manifests/.
#                      ${{ secrets.GITHUB_TOKEN }} works when pushing to the same repo.
#
# No KUBECONFIG or cluster credentials are needed for the build-and-test or
# build-images jobs. The deploy job emits manifests for GitOps instead of
# applying them directly to a cluster.
#
# ── Sun CI contract ──────────────────────────────────────────────────────────
#
# PHASE 1 — Build (user-owned, Sun-stable):
#   Compile and test OCaml code using: eval $(opam env) && dune build && dune runtest
#   Build and push Docker images using your registry's docker login + docker build/push.
#   Sun does not own this step today; a future `sun build` command will replace it.
#
# PHASE 2 — Deploy (Sun-owned, typed contract):
#   sun deploy <target> --emit-plan-to plan.json --dry-run   # capture typed deployment intent
#   sun deploy <target> --emit-to manifests/ --image-tag $SHA  # render K8s YAML (GitOps)
#
# Never duplicate the plan/render/execute logic from sun deploy in CI.
# All deployment decisions (image tags, namespaces, service discovery, secrets)
# belong in the CLI pipeline. CI only provides inputs (--registry, --image-tag).
# ─────────────────────────────────────────────────────────────────────────────

name: Sun CI

on:
  push:
    branches: [main]
  pull_request:

env:
  REGISTRY:   ${{ secrets.REGISTRY }}
  IMAGE_TAG:  ${{ github.sha }}
  SUN_TARGET: ${{ vars.SUN_TARGET }}

# ── Job 1: compile + unit tests ──────────────────────────────────────────── #
jobs:
  build-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up OCaml
        uses: ocaml/setup-ocaml@v3
        with:
          ocaml-compiler: "5.4.1"
          opam-depext: false

      - name: Install system deps
        run: sudo apt-get install -y librdkafka-dev libpq-dev

      - name: Install opam deps
        run: opam install . --deps-only --with-test -y

      - name: Build
        run: eval $(opam env) && dune build

      - name: Test
        run: eval $(opam env) && dune runtest

# ── Job 2: build and push service images ────────────────────────────────── #
  build-images:
    needs: build-and-test
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up OCaml
        uses: ocaml/setup-ocaml@v3
        with:
          ocaml-compiler: "5.4.1"
          opam-depext: false

      - name: Install system deps
        run: sudo apt-get install -y librdkafka-dev libpq-dev

      - name: Install opam deps
        run: opam install . --deps-only -y

      - name: Build service binaries
        run: eval $(opam env) && dune build

      # Registry login — uncomment the block that matches your registry:

      # AWS ECR:
      # - uses: aws-actions/configure-aws-credentials@v4
      #   with:
      #     aws-access-key-id:     ${{ secrets.AWS_ACCESS_KEY_ID }}
      #     aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      #     aws-region:            ${{ secrets.AWS_REGION }}
      # - run: |
      #     aws ecr get-login-password | \
      #       docker login --username AWS --password-stdin ${{ secrets.REGISTRY }}

      # GCP Artifact Registry:
      # - uses: google-github-actions/auth@v2
      #   with: { credentials_json: '${{ secrets.GCP_SA_KEY }}' }
      # - run: gcloud auth configure-docker ${{ secrets.REGISTRY }}

      # Generic (Docker Hub, GHCR, etc.):
      - name: Log in to registry
        run: |
          echo "${{ secrets.REGISTRY_PASSWORD }}" | \
            docker login "$REGISTRY" -u "${{ secrets.REGISTRY_USER }}" --password-stdin

      - name: Build and push images
        run: |
          SHORT_SHA=${IMAGE_TAG::7}
          # TODO(sun-build): This step will be replaced by `sun build --registry $REGISTRY`
          # once Sun publishes a stable build command. Until then, build images explicitly.
          # sun up discovers services from app/<domain>/<name>/Dockerfile.
          # Build and push each image explicitly here:
          find app -name Dockerfile | while read dockerfile; do
            dir=$(dirname "$dockerfile")
            svc=$(basename "$dir" | tr '_' '-')
            image="${REGISTRY}/{{name}}/${svc}:${SHORT_SHA}"
            docker build -t "$image" -f "$dockerfile" .
            docker push "$image"
          done

# ── Job 3: emit deployment plan + GitOps manifests ──────────────────────── #
# This job runs only on pushes to main (not on pull requests).
# `sun deploy <target> --emit-plan-to plan.json` records the full deployment intent
# (images, namespaces, config) without applying anything — useful for auditing.
# `sun deploy <target> --emit-to manifests/` renders Kubernetes YAML to manifests/.
# An Argo CD Application watching that directory reconciles the change
# automatically; no KUBECONFIG or cluster credentials are required in CI.
  deploy:
    needs: build-images
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          token: ${{ secrets.GITOPS_TOKEN || secrets.GITHUB_TOKEN }}
          fetch-depth: 0

      - name: Set up OCaml
        uses: ocaml/setup-ocaml@v3
        with:
          ocaml-compiler: "5.4.1"
          opam-depext: false

      - name: Install system deps
        run: sudo apt-get install -y librdkafka-dev libpq-dev

      - name: Install opam deps
        run: opam install . --deps-only -y

      - name: Build sun binary
        run: eval $(opam env) && dune build cli/sun/bin/main.exe
        # TODO: replace with a pre-built binary download once Sun publishes releases.

      - name: Export deployment plan
        run: |
          eval $(opam env)
          # Equivalent Sun command: sun deploy <target> --emit-plan-to plan.json --dry-run
          _build/default/cli/sun/bin/main.exe deploy "$SUN_TARGET" \
            --registry  "$REGISTRY" \
            --image-tag "${IMAGE_TAG::7}" \
            --emit-plan-to plan.json \
            --dry-run
        # plan.json captures the full intent for this deploy (images, namespaces, config).

      - name: Upload deployment plan
        uses: actions/upload-artifact@v4
        with:
          name: deployment-plan-${{ github.sha }}
          path: plan.json

      - name: Emit GitOps manifests
        run: |
          eval $(opam env)
          # Equivalent Sun command: sun deploy <target> --emit-to manifests/
          _build/default/cli/sun/bin/main.exe deploy "$SUN_TARGET" \
            --registry  "$REGISTRY" \
            --image-tag "${IMAGE_TAG::7}" \
            --emit-to   manifests/
        # Writes rendered Kubernetes YAML to manifests/.
        # Argo CD (or Flux) watches this directory and reconciles automatically.

      - name: Commit and push manifests
        run: |
          git config user.email "ci@sun.dev"
          git config user.name  "Sun CI"
          git add manifests/
          git diff --cached --quiet && echo "no manifest changes" && exit 0
          git commit -m "deploy: ${IMAGE_TAG::7}"
          git push
|tpl}

let tpl_github_deploy = {tpl|# CI/CD — deploy to your Sun cluster on every push to main.
#
# Required secrets (set in GitHub repo Settings → Secrets):
#   KUBECONFIG_B64   base64-encoded kubeconfig: $(cat ~/.kube/config | base64)
#   REGISTRY         container registry prefix, e.g.:
#                      AWS ECR:  123456789.dkr.ecr.us-east-1.amazonaws.com
#                      GCP AR:   us-central1-docker.pkg.dev/my-project/{{name}}
#                      Docker Hub: docker.io/myorg
#
# Required repo variable (Settings → Secrets and variables → Actions → Variables —
# not a secret, this is just a path):
#   SUN_TARGET       deployment target, <env>/<provider>/<region>, e.g. prod/aws/us-east-1.
#                    Requires a matching sun/<env>/<provider>/<region>.yml file
#                    committed in this repo -- this workspace ships a placeholder
#                    at sun/prod/aws/us-east-1.yml; rename it to match your real
#                    target if it isn't prod/aws/us-east-1.
#
# For ECR add AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION and
# uncomment the ECR login step below.
#
# See platform/infra/ci/ in the Sun repo for the full GitOps (Argo CD) variant.

name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: ocaml/setup-ocaml@v3
        with:
          ocaml-compiler: "5.4.1"
          opam-depext: false

      - name: Install system deps
        run: sudo apt-get install -y librdkafka-dev libpq-dev

      - name: Build
        run: |
          opam install . --deps-only -y
          eval $(opam env) && dune build

      # ── Registry login ───────────────────────────────────────────────── #
      # Uncomment the block that matches your registry:

      # AWS ECR:
      # - uses: aws-actions/configure-aws-credentials@v4
      #   with:
      #     aws-access-key-id:     ${{ secrets.AWS_ACCESS_KEY_ID }}
      #     aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      #     aws-region:            ${{ secrets.AWS_REGION }}
      # - run: |
      #     aws ecr get-login-password | \
      #       docker login --username AWS --password-stdin ${{ secrets.REGISTRY }}

      # GCP Artifact Registry:
      # - uses: google-github-actions/auth@v2
      #   with: { credentials_json: '${{ secrets.GCP_SA_KEY }}' }
      # - run: gcloud auth configure-docker ${{ secrets.REGISTRY }}

      # Docker Hub:
      # - uses: docker/login-action@v3
      #   with:
      #     username: ${{ secrets.DOCKERHUB_USERNAME }}
      #     password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build and push images
        env:
          REGISTRY: ${{ secrets.REGISTRY }}
          SHA:      ${{ github.sha }}
        run: |
          SHORT_SHA=${SHA::7}
          find app -name Dockerfile | while read dockerfile; do
            dir=$(dirname "$dockerfile")
            svc=$(basename "$dir" | tr '_' '-')
            image="${REGISTRY}/{{name}}/${svc}:${SHORT_SHA}"
            docker build -t "$image" -f "$dockerfile" .
            docker push "$image"
          done

      - name: Deploy
        env:
          REGISTRY:   ${{ secrets.REGISTRY }}
          SHA:        ${{ github.sha }}
          SUN_TARGET: ${{ vars.SUN_TARGET }}
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.KUBECONFIG_B64 }}" | base64 -d > ~/.kube/config
          eval $(opam env)
          sun deploy "$SUN_TARGET" \
            --image-tag "${SHA::7}" \
            --registry  "$REGISTRY"

      - name: Status
        run: eval $(opam env) && sun status
|tpl}

let tpl_dockerfile = {tpl|# Stage 1: compile inside ubuntu-24.04 so the binary links against glibc 2.39.
# sun up resolves vendor/ symlinks into the build context before running docker build.
FROM ocaml/opam:ubuntu-24.04-ocaml-5.4 AS build
RUN sudo apt-get update && sudo apt-get install -y \
    librdkafka-dev libpq-dev libssl-dev libgmp-dev pkg-config && \
    sudo rm -rf /var/lib/apt/lists/*
RUN opam install -y --no-self-upgrade \
    eio eio_main cohttp-eio yojson cmdliner base64 uri cstruct mtime \
    tls-eio x509 domain-name ptime otoml \
    caqti-eio caqti-driver-postgresql
COPY --chown=opam:opam . /workspace
WORKDIR /workspace
RUN opam exec -- dune build {{repo_dir}}/bin/main.exe

# Stage 2: minimal runtime image
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y librdkafka1 libpq5 ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/_build/default/{{repo_dir}}/bin/main.exe /usr/local/bin/{{binary}}
# Run as nobody (uid 65534) — matches securityContext in generated k8s manifests
USER 65534
CMD ["/usr/local/bin/{{binary}}"]
|tpl}

let tpl_dockerignore = {tpl|_build/
.git/
*.docker-ctx/
|tpl}

(* sun deploy deliberately refuses to run against a target with no
   sun/<env>/<provider>/<region>.yml file, even an empty one -- otherwise a
   typo'd target would silently inherit sun.yml's shared defaults and
   deploy anyway. This placeholder exists so a freshly scaffolded workspace
   has a real first target instead of failing before its first deploy;
   rename/move it (and update SUN_TARGET below) to your actual target. *)
let tpl_deploy_target = {tpl|# Placeholder target for `sun deploy prod/aws/us-east-1`.
# Rename this file's path (sun/<env>/<provider>/<region>.yml) to your real
# deployment target, and set the SUN_TARGET repository variable in GitHub
# (used by .github/workflows/deploy.yml) to match.
#
# target:
#   registry: <your-registry-url>
|tpl}

(* ── Workspace scaffold templates ─────────────────────────────────────────── *)

(* events/payments/charged.ml — satisfies Kafka_service.MESSAGE *)
let ws_charged_ml = {tpl|type t = {
  id             : string;
  amount_cents   : int;
  customer_id    : string;
  currency       : string;
  correlation_id : string;
}

let topic_name = Kafka_service.topic_name_exn "{{name}}-payments-charges"

let schema = {|{
  "type": "object",
  "properties": {
    "id":             { "type": "string"  },
    "amount_cents":   { "type": "integer" },
    "customer_id":    { "type": "string"  },
    "currency":       { "type": "string"  },
    "correlation_id": { "type": "string"  }
  },
  "required": ["id", "amount_cents", "customer_id", "currency", "correlation_id"]
}|}

let encode t = `Assoc [
  ("id",             `String t.id);
  ("amount_cents",   `Int    t.amount_cents);
  ("customer_id",    `String t.customer_id);
  ("currency",       `String t.currency);
  ("correlation_id", `String t.correlation_id);
]

let required_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _              -> Error (name ^ " must be a string")
  | None                -> Error (name ^ " is required")

let required_int fields name =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | Some _            -> Error (name ^ " must be an integer")
  | None              -> Error (name ^ " is required")

let ( let* ) = Result.bind

let decode = function
  | `Assoc fields ->
    let* id = required_string fields "id" in
    let* amount_cents = required_int fields "amount_cents" in
    let* customer_id = required_string fields "customer_id" in
    let* currency = required_string fields "currency" in
    let* correlation_id = required_string fields "correlation_id" in
    Ok { id; amount_cents; customer_id; currency; correlation_id }
  | _ -> Error "expected object"
|tpl}

(* events/payments/dune *)
let ws_events_dune = {tpl|(library
 (name {{name}}_payments_events)
 (wrapped false)
 (modules Charged)
 (libraries kafka_eio_service yojson))
|tpl}

(* lib/notification.ml — shared storage module *)
let ws_notification_ml = {tpl|(* Notification storage — generated by sun new workspace.
   Run `sun migrate` to create the table in the cluster. *)

let insert_q =
  Caqti_request.Infix.(Caqti_type.(t4 string string int string) ->. Caqti_type.unit)
    "INSERT INTO {{name}}_notifications \
     (charge_id, customer_id, amount_cents, currency) \
     VALUES (?, ?, ?, ?)"

let list_q =
  Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.(t4 string string int string))
    "SELECT charge_id, customer_id, amount_cents, currency \
     FROM {{name}}_notifications \
     ORDER BY created_at DESC LIMIT 20"

let insert pool ~charge_id ~customer_id ~amount_cents ~currency =
  Pg_db.exec pool insert_q (charge_id, customer_id, amount_cents, currency)

let list_recent pool =
  Pg_db.collect pool list_q ()
|tpl}

(* lib/dune — shared storage library *)
let ws_storage_dune = {tpl|(library
 (name {{name}}_storage)
 (wrapped false)
 (modules Notification)
 (libraries pg-eio caqti))
|tpl}

(* app/payments/charge_svc/lib/handler.ml *)
let ws_svc_handler_ml = {tpl|(* POST /charges  — publish Charged to Kafka
   GET  /health      — liveness probe
   GET  /notifications — list notifications written by notify_worker *)

let routes pool ~publish_charged = [
  Route.get "/health" ~auth:`Public (fun _req ->
    Response.ok "ok"
  );
  Route.post "/charges" ~auth:`Public (fun req ->
    let required_string json name =
      match Yojson.Basic.Util.member name json with
      | `String value -> Ok value
      | `Null         -> Error (name ^ " is required")
      | _             -> Error (name ^ " must be a string")
    in
    let required_int json name =
      match Yojson.Basic.Util.member name json with
      | `Int value -> Ok value
      | `Null      -> Error (name ^ " is required")
      | _          -> Error (name ^ " must be an integer")
    in
    let decode_charge json =
      Result.bind (required_string json "customer_id") @@ fun customer_id ->
      Result.bind (required_int json "amount_cents") @@ fun amount_cents ->
      Result.map
        (fun currency -> customer_id, amount_cents, currency)
        (required_string json "currency")
    in
    let parsed =
      try Ok (Yojson.Basic.from_string req.body)
      with Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
    in
    match Result.bind parsed decode_charge with
    | Error msg ->
      Response.bad_request msg
    | Ok (customer_id, amount_cents, currency) ->
      let charge_id = Printf.sprintf "ch_%06d" (Random.int 999999) in
      let event : Charged.t = {
        id             = charge_id;
        customer_id;
        amount_cents;
        currency;
        correlation_id = Option.value (Request.header req "x-correlation-id")
                           ~default:charge_id;
      } in
      match publish_charged event with
      | Ok () ->
        Response.json ~status:202
          (Printf.sprintf {|{"id":"%s","accepted":true}|} charge_id)
      | Error msg ->
        Response.internal_error ("publish failed: " ^ msg)
  );
  Route.get "/notifications" ~auth:`Public (fun _req ->
    match Notification.list_recent pool with
    | Error _  -> Response.json ~status:500 {|{"error":"db unavailable"}|}
    | Ok rows  ->
      let row_json (charge_id, customer_id, amount_cents, currency) =
        `Assoc [
          ("charge_id",    `String charge_id);
          ("customer_id",  `String customer_id);
          ("amount_cents", `Int amount_cents);
          ("currency",     `String currency);
        ]
      in
      Response.json (Yojson.Basic.to_string (`List (List.map row_json rows)))
  );
]
|tpl}

(* app/payments/charge_svc/lib/dune *)
let ws_svc_lib_dune = {tpl|(library
 (name {{name}}_payments_charge_svc)
 (wrapped false)
 (modules Handler)
 (libraries {{name}}_storage {{name}}_payments_events sun_svc yojson))
|tpl}

(* app/payments/charge_svc/bin/main.ml *)
let ws_svc_bin_ml = {tpl|let fatal msg =
  prerr_endline ("error: " ^ msg);
  exit 1

let env_nonempty name =
  match Sys.getenv_opt name with
  | Some value when value <> "" -> Some value
  | _ -> None

let optional_log_backend ~net ~clock = function
  | None     -> Obs_eio.stdout
  | Some url ->
    Obs_loki.create ~net ~clock ~url
      ~label_names:[Obs_loki.stream_label_exn "team"] ()

let require_kafka label = function
  | Ok value -> value
  | Error e  -> fatal (label ^ ": " ^ Kafka_service.error_to_string e)

let require_db_pool ~sw ~stdenv =
  match Pg_db.of_env ~sw ~stdenv () with
  | Ok pool -> pool
  | Error e -> fatal ("db pool: " ^ Pg_error.to_string e)

let () =
  let loki_url     = env_nonempty "LOKI_URL" in
  let tempo_url    = env_nonempty "TEMPO_URL" in
  let kafka_config = Kafka_service.config_of_env () |> require_kafka "kafka config" in
  Eio_main.run @@ fun env ->
  let log_backend = optional_log_backend ~net:env#net ~clock:env#clock loki_url in
  let prom, render = Obs_prometheus.create () in
  let backend = Obs_eio.compose log_backend prom in
  let backend = match tempo_url with
    | None     -> backend
    | Some url -> Obs_eio.compose backend (Obs_tempo.create ~net:env#net ~clock:env#clock ~url ())
  in
  let ot =
    Obs_eio.with_context
      (Obs_eio.create ~service:"{{name}}-charge-svc" ~mono_clock:env#mono_clock
         ~backend ())
      [("team", "payments")]
  in
  Eio.Switch.run @@ fun sw ->
  let pool = require_db_pool ~sw ~stdenv:(env :> Caqti_eio.stdenv) in
  let kafka = Kafka_service.create kafka_config ~sw |> require_kafka "kafka create" in
  let charged_topic =
    Kafka_service.register kafka ~net:env#net ~clock:env#clock (module Charged)
    |> require_kafka "kafka register"
  in
  let publish_charged event =
    match Eio.Promise.await (Kafka_service.publish kafka charged_topic event) with
    | Ok () -> Ok ()
    | Error e -> Error (Kafka.Error.to_string e)
  in
  Service.run (Handler.routes pool ~publish_charged) ~env ~ot ~metrics_renderer:render ()
  |> Result.map_error Service.run_error_to_string
  |> function Ok () -> () | Error e -> fatal e
|tpl}

(* app/payments/charge_svc/bin/dune *)
let ws_svc_bin_dune = {tpl|(executable
 (name main)
 (libraries
  {{name}}_payments_charge_svc
  sun_svc kafka_eio_service obs-eio obs-loki-eio obs-prometheus-eio obs-tempo-eio
  pg-eio caqti-eio caqti-eio.unix caqti-driver-postgresql
  eio_main))
|tpl}

(* app/comms/notify_worker/lib/notify_worker.ml — satisfies Worker.WORKER *)
let ws_worker_ml = {tpl|(* Inject pool and observability handle via functor so there's no mutable state.
   Worker.Make requires module Message, group_id, and handle inside the functor. *)
module Make (Config : sig
  val pool : Pg_db.pool
  val ot   : Obs_eio.t
end) = struct

  module Message = Charged

  let group_id = "{{name}}-comms-notify-worker"

  let handle (msg : Message.t) ~trace_ctx:_ =
    Obs_eio.log_standalone Config.ot Obs_eio.Info
      ~fields:[("charge_id", msg.id); ("customer_id", msg.customer_id);
               ("amount_cents", string_of_int msg.amount_cents)]
      "charge event received";
    match Notification.insert Config.pool
            ~charge_id:msg.id ~customer_id:msg.customer_id
            ~amount_cents:msg.amount_cents ~currency:msg.currency with
    | Ok ()   -> Ok ()
    | Error e ->
      Obs_eio.log_standalone Config.ot Obs_eio.Error
        ~fields:[("error", Pg_error.to_string e)]
        "db insert failed";
      Error (Pg_error.to_string e)

end
|tpl}

(* app/comms/notify_worker/lib/dune *)
let ws_worker_lib_dune = {tpl|(library
 (name {{name}}_comms_notify)
 (wrapped false)
 (modules Notify_worker)
 (libraries
  {{name}}_storage {{name}}_payments_events
  kafka_eio_service obs-eio pg-eio))
|tpl}

(* app/comms/notify_worker/bin/main.ml *)
let ws_worker_bin_ml = {tpl|let fatal msg =
  prerr_endline ("error: " ^ msg);
  exit 1

let env_nonempty name =
  match Sys.getenv_opt name with
  | Some value when value <> "" -> Some value
  | _ -> None

let optional_log_backend ~net ~clock = function
  | None     -> Obs_eio.stdout
  | Some url ->
    Obs_loki.create ~net ~clock ~url
      ~label_names:[Obs_loki.stream_label_exn "team"] ()

let require_db_pool ~sw ~stdenv =
  match Pg_db.of_env ~sw ~stdenv () with
  | Ok pool -> pool
  | Error e -> fatal ("db pool: " ^ Pg_error.to_string e)

let require_kafka label = function
  | Ok value -> value
  | Error e  -> fatal (label ^ ": " ^ Kafka_service.error_to_string e)

let () =
  let loki_url     = env_nonempty "LOKI_URL" in
  let kafka_config = Kafka_service.config_of_env () |> require_kafka "kafka config" in
  Eio_main.run @@ fun env ->
  let log_backend = optional_log_backend ~net:env#net ~clock:env#clock loki_url in
  let prom, render = Obs_prometheus.create () in
  let ot =
    Obs_eio.with_context
      (Obs_eio.create ~service:"{{name}}-notify-worker" ~mono_clock:env#mono_clock
         ~backend:(Obs_eio.compose log_backend prom) ())
      [("team", "comms")]
  in
  Eio.Switch.run @@ fun sw ->
  let pool = require_db_pool ~sw ~stdenv:(env :> Caqti_eio.stdenv) in
  let module W = Notify_worker.Make(struct
    let pool = pool
    let ot   = ot
  end) in
  let module WR = Worker.Make(W) in
  WR.run ~env ~config:kafka_config ~ot ~metrics_renderer:render ()
  |> Result.map_error Worker.run_error_to_string
  |> function Ok () -> () | Error msg -> fatal msg
|tpl}

(* app/comms/notify_worker/bin/dune *)
let ws_worker_bin_dune = {tpl|(executable
 (name main)
 (libraries
  {{name}}_comms_notify sun_worker kafka_eio_service
  obs-eio obs-loki-eio obs-prometheus-eio
  pg-eio caqti-eio caqti-eio.unix caqti-driver-postgresql
  eio_main))
|tpl}

(* db/migrations/0001_notifications.sql *)
let ws_migration_sql = {tpl|CREATE TABLE IF NOT EXISTS {{name}}_notifications (
  id           BIGSERIAL    PRIMARY KEY,
  charge_id    TEXT         NOT NULL,
  customer_id  TEXT         NOT NULL,
  amount_cents INTEGER      NOT NULL,
  currency     TEXT         NOT NULL DEFAULT 'usd',
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
|tpl}

(* db/migrations/0001_notifications.down.sql *)
let ws_migration_down_sql = {tpl|DROP TABLE IF EXISTS {{name}}_notifications;
|tpl}

(* test/test_schemas.ml — schema compatibility CI gate *)
let ws_test_schemas_ml = {tpl|(* Schema backward-compatibility check — generated by sun new workspace.
   Run against a live schema registry: SCHEMA_REGISTRY_URL=http://... dune test
   If SCHEMA_REGISTRY_URL is not set the test is skipped (safe for unit CI). *)
let () =
  match Sys.getenv_opt "SCHEMA_REGISTRY_URL" with
  | None ->
    Printf.printf "SCHEMA_REGISTRY_URL not set — skipping schema compat check\n%!"
  | Some registry_url ->
    Eio_main.run (fun env ->
      match Kafka_service.Schema.check_all
              ~net:env#net
              ~clock:env#clock
              ~registry_url
              [ (module Charged) ]
      with
      | Ok () ->
        Printf.printf "schema compatibility: ok\n%!"
      | Error e ->
        Printf.eprintf "schema compatibility FAILED: %s\n%!" (Kafka_service.error_to_string e);
        exit 1
    )
|tpl}

(* test/dune *)
let ws_test_dune = {tpl|(executable
 (name test_schemas)
 (libraries kafka_eio_service eio_main {{name}}_payments_events))
|tpl}

(* ── Generic primitive templates ──────────────────────────────────────────── *)

(* Generic svc: lib/handler.ml *)
let svc_handler_ml = {tpl|let routes = [
  Route.get "/health" ~auth:`Public (fun _req ->
    Response.ok "ok"
  );
]
|tpl}

(* Generic svc: lib/dune *)
let svc_lib_dune = {tpl|(library
 (name {{lib}})
 (wrapped false)
 (modules Handler)
 (libraries sun_svc))
|tpl}

(* Generic svc: bin/main.ml *)
let svc_bin_ml = {tpl|let fatal msg =
  prerr_endline ("error: " ^ msg);
  exit 1

let () = Eio_main.run @@ fun env ->
  Service.run Handler.routes ~env ()
  |> Result.map_error Service.run_error_to_string
  |> function Ok () -> () | Error e -> fatal e
|tpl}

(* Generic svc: bin/dune *)
let svc_bin_dune = {tpl|(executable
 (name main)
 (libraries {{lib}} sun_svc eio_main))
|tpl}

(* Generic worker: lib/<name>_worker.ml — satisfies Worker.WORKER; replace the
   stub Message with your event module. *)
let worker_lib_ml = {tpl|(* Replace Message with your event module, e.g.:
     module Message = My_team_events.My_event *)
module Message = struct
  type t = { id : string }
  let topic_name = Kafka_service.topic_name_exn "{{domain}}-{{name}}-events"
  let schema = {|{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}|}
  let encode t = `Assoc [("id", `String t.id)]
  let required_string fields name =
    match List.assoc_opt name fields with
    | Some (`String value) -> Ok value
    | Some _              -> Error (name ^ " must be a string")
    | None                -> Error (name ^ " is required")
  let ( let* ) = Result.bind
  let decode = function
    | `Assoc fields ->
      let* id = required_string fields "id" in
      Ok { id }
    | _ -> Error "expected object"
end

let group_id = "{{domain}}-{{name}}-worker"

let handle (msg : Message.t) ~trace_ctx:_ =
  Printf.printf "[{{name}}-worker] received id=%s\n%!" msg.id;
  (* Add side effects here, then return Ok (). The worker acknowledges
     (commits the offset) for you, only after this returns Ok — there is no
     ack to call. Returning Error causes the message to be retried. *)
  Ok ()
|tpl}

(* Generic worker: lib/dune *)
let worker_lib_dune = {tpl|(library
 (name {{lib}})
 (wrapped false)
 (modules {{Mod}})
 (libraries kafka_eio_service yojson))
|tpl}

(* Generic worker: bin/main.ml *)
let worker_bin_ml = {tpl|let fatal msg =
  prerr_endline ("error: " ^ msg);
  exit 1

let require_kafka label = function
  | Ok value -> value
  | Error e  -> fatal (label ^ ": " ^ Kafka_service.error_to_string e)

let () = Eio_main.run @@ fun env ->
  let config = Kafka_service.config_of_env () |> require_kafka "kafka config" in
  let backend, render = Obs_prometheus.create () in
  let ot = Obs_eio.create ~service:"{{name}}-worker"
             ~mono_clock:env#mono_clock ~backend () in
  let module W = Worker.Make({{Mod}}) in
  W.run ~env ~config ~ot ~metrics_renderer:render ()
  |> Result.map_error Worker.run_error_to_string
  |> function Ok () -> () | Error msg -> fatal msg
|tpl}

(* Generic worker: bin/dune *)
let worker_bin_dune = {tpl|(executable
 (name main)
 (libraries {{lib}} sun_worker kafka_eio_service obs-eio obs-prometheus-eio eio_main))
|tpl}

(* Generic fn: lib/<name>_fn.ml — satisfies Fn.FN *)
let fn_lib_ml = {tpl|let trigger = Fn.Cron "0 * * * *"

let run () =
  Printf.printf "[{{name}}-fn] running\n%!";
  Ok ()
|tpl}

(* Generic fn: lib/dune *)
let fn_lib_dune = {tpl|(library
 (name {{lib}})
 (wrapped false)
 (modules {{Mod}}))
|tpl}

(* Generic fn: bin/main.ml *)
let fn_bin_ml = {tpl|let fatal msg =
  prerr_endline ("error: " ^ msg);
  exit 1

let () = Eio_main.run @@ fun env ->
  let module F = Fn.Make({{Mod}}) in
  match F.run ~env () with
  | Ok () -> ()
  | Error `Signalled -> exit 130
  | Error e -> fatal (Fn.run_error_to_string e)
|tpl}

(* Generic fn: bin/dune *)
let fn_bin_dune = {tpl|(executable
 (name main)
 (libraries {{lib}} sun_fn eio_main))
|tpl}

(* Generic event: <name>.ml — satisfies Kafka_service.MESSAGE *)
let event_ml = {tpl|type t = {
  id      : string;
  payload : string;
}

let topic_name = Kafka_service.topic_name_exn "{{team}}-{{name}}s"

let schema = {|{
  "type": "object",
  "properties": {
    "id":      { "type": "string" },
    "payload": { "type": "string" }
  },
  "required": ["id", "payload"]
}|}

let encode t = `Assoc [
  ("id",      `String t.id);
  ("payload", `String t.payload);
]

let required_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _              -> Error (name ^ " must be a string")
  | None                -> Error (name ^ " is required")

let ( let* ) = Result.bind

let decode = function
  | `Assoc fields ->
    let* id = required_string fields "id" in
    let* payload = required_string fields "payload" in
    Ok { id; payload }
  | _ -> Error "expected object"
|tpl}
