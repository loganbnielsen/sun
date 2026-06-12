open Cmdliner

let subst = Sun_cli_scaffold.subst
let write  = Sun_cli_scaffold.write_file
let link   = Sun_cli_scaffold.link_dir
let norm   = Sun_cli_scaffold.normalize
let cap    = Sun_cli_scaffold.capitalize_name

let is_sun_home dir =
  Sys.file_exists (Filename.concat dir "framework/sun-svc/lib/dune")
  && Sys.file_exists (Filename.concat dir "integrations/kafka/kafka-eio-service/lib/dune")

let rec realpath path =
  let path =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path
  in
  try
    let target = Unix.readlink path in
    let target =
      if Filename.is_relative target then Filename.concat (Filename.dirname path) target
      else target
    in
    realpath target
  with Unix.Unix_error ((Unix.EINVAL | Unix.ENOENT), _, _) -> path

let rec find_ancestor pred dir =
  if pred dir then Some dir
  else
    let parent = Filename.dirname dir in
    if parent = dir then None else find_ancestor pred parent

let infer_sun_home () =
  match Sys.getenv_opt "SUN_HOME" with
  | Some dir when is_sun_home dir -> Some dir
  | Some _ -> None  (* invalid SUN_HOME — NOTE in new_workspace covers this *)
  | None ->
    let exe =
      try Unix.readlink "/proc/self/exe"
      with Unix.Unix_error _ -> Sys.executable_name
    in
    find_ancestor is_sun_home (Filename.dirname (realpath exe))

let link_sun_sources workspace =
  match infer_sun_home () with
  | None -> false
  | Some sun_home ->
    link ~path:(workspace ^ "/vendor/framework")
      ~target:(Filename.concat sun_home "framework");
    link ~path:(workspace ^ "/vendor/integrations")
      ~target:(Filename.concat sun_home "integrations");
    true

(* ── Shared templates ────────────────────────────────────────────────── *)

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
db/migrations/            ← SQL migration files
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

(* ── Sun CI workflow (.github/workflows/sun-ci.yml) ─────────────────── *)
(* Three-job pipeline:
     1. build-and-test  - dune build + dune runtest.  No cluster credentials.
     2. build-images    - dune build + docker build/push per service.
                          Registry creds only; skipped for pull requests.
     3. deploy          - sun deploy --emit-plan-to (plan export) + --emit-to
                          (GitOps manifest emit).  No KUBECONFIG needed.
   The GitOps job commits manifests/ back to the repo; an Argo CD Application
   watching that path reconciles the change automatically.
*)
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
# Optional (GitOps push step):
#   GITOPS_TOKEN       GitHub token with repo-write access to commit manifests/.
#                      ${{ secrets.GITHUB_TOKEN }} works when pushing to the same repo.
#
# No KUBECONFIG or cluster credentials are needed for the build-and-test or
# build-images jobs. The deploy job emits manifests for GitOps instead of
# applying them directly to a cluster.

name: Sun CI

on:
  push:
    branches: [main]
  pull_request:

env:
  REGISTRY:  ${{ secrets.REGISTRY }}
  IMAGE_TAG: ${{ github.sha }}

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
# `sun deploy --emit-plan-to plan.json` records the full deployment intent
# (images, namespaces, config) without applying anything — useful for auditing.
# `sun deploy --emit-to manifests/` renders Kubernetes YAML to manifests/.
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
          # Equivalent Sun command: sun deploy --emit-plan-to plan.json --dry-run
          _build/default/cli/sun/bin/main.exe deploy \
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
          # Equivalent Sun command: sun deploy --emit-to manifests/
          _build/default/cli/sun/bin/main.exe deploy \
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

      - uses: ocaml/setup-ocaml@v2
        with:
          ocaml-compiler: "5.4"
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
          REGISTRY: ${{ secrets.REGISTRY }}
          SHA:      ${{ github.sha }}
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.KUBECONFIG_B64 }}" | base64 -d > ~/.kube/config
          eval $(opam env)
          sun deploy \
            --image-tag "${SHA::7}" \
            --registry  "$REGISTRY"

      - name: Status
        run: eval $(opam env) && sun status
|tpl}

let tpl_dockerfile = {tpl|# sun up compiles locally with dune, then runs:
#   docker build -t <image> -f {{repo_dir}}/Dockerfile <repo_root>
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y librdkafka1 libpq5 ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY _build/default/{{repo_dir}}/bin/main.exe /usr/local/bin/{{binary}}
# Run as nobody (uid 65534) — matches securityContext in generated k8s manifests
USER 65534
CMD ["/usr/local/bin/{{binary}}"]
|tpl}

(* ── Workspace scaffold templates ────────────────────────────────────── *)

(* events/payments/charged.ml — satisfies Kafka_service.MESSAGE *)
let ws_charged_ml = {tpl|type t = {
  id             : string;
  amount_cents   : int;
  customer_id    : string;
  currency       : string;
  correlation_id : string;
}

let topic_name = "{{name}}-payments-charges"

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

let decode = function
  | `Assoc fields ->
    let get_s k = match List.assoc_opt k fields with Some (`String s) -> Some s | _ -> None in
    let get_i k = match List.assoc_opt k fields with Some (`Int i)    -> Some i | _ -> None in
    (match get_s "id", get_i "amount_cents", get_s "customer_id",
           get_s "currency", get_s "correlation_id" with
     | Some id, Some amount_cents, Some customer_id,
       Some currency, Some correlation_id ->
       Ok { id; amount_cents; customer_id; currency; correlation_id }
     | _ -> Error "missing required fields")
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
  Db.exec pool insert_q (charge_id, customer_id, amount_cents, currency)

let list_recent pool =
  Db.collect pool list_q ()
|tpl}

(* lib/dune — shared storage library *)
let ws_storage_dune = {tpl|(library
 (name {{name}}_storage)
 (wrapped false)
 (modules Notification)
 (libraries sun_storage caqti))
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
    let j     = Yojson.Basic.from_string req.body in
    let get_s k = Yojson.Basic.Util.(j |> member k |> to_string_option
                  |> Option.value ~default:"") in
    let get_i k = Yojson.Basic.Util.(j |> member k |> to_int_option
                  |> Option.value ~default:0) in
    let charge_id = Printf.sprintf "ch_%06d" (Random.int 999999) in
    let event : Charged.t = {
      id             = charge_id;
      customer_id    = get_s "customer_id";
      amount_cents   = get_i "amount_cents";
      currency       = get_s "currency";
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
    match pool with
    | None ->
      Response.json {|[]|}
    | Some p ->
      (match Notification.list_recent p with
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
         Response.json (Yojson.Basic.to_string (`List (List.map row_json rows))))
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
let ws_svc_bin_ml = {tpl|let () =
  let postgres_url = Sys.getenv_opt "POSTGRES_URL" in
  let loki_url     = Sys.getenv_opt "LOKI_URL" in
  let kafka_config = Kafka_service.config_of_env () in
  Eio_main.run @@ fun env ->
  let log_backend = match loki_url with
    | None     -> Obs.stdout
    | Some url ->
      Obs_loki.create ~net:env#net ~clock:env#clock ~url
        ~label_names:["service"; "team"] ()
  in
  let prom, render = Obs_prometheus.create () in
  let ot =
    Obs.with_context
      (Obs.create ~service:"{{name}}-charge-svc" ~mono_clock:env#mono_clock
         ~backend:(Obs.compose log_backend prom))
      [("team", "payments")]
  in
  Eio.Switch.run @@ fun sw ->
  let pool = match postgres_url with
    | None     -> None
    | Some url ->
      (match Db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
       | Error _ -> None
       | Ok p    -> Some p)
  in
  let kafka =
    match Kafka_service.create kafka_config ~sw with
    | Error e -> failwith ("kafka create: " ^ e)
    | Ok svc  -> svc
  in
  let charged_topic =
    match Kafka_service.register kafka ~net:env#net ~clock:env#clock
            (module Charged) with
    | Error e -> failwith ("kafka register: " ^ e)
    | Ok t    -> t
  in
  let publish_charged event =
    match Eio.Promise.await (Kafka_service.publish kafka charged_topic event) with
    | Ok () -> Ok ()
    | Error e -> Error (Kafka_error.to_string e)
  in
  Service.run (Handler.routes pool ~publish_charged) ~env ~ot ~metrics_renderer:render ()
|tpl}

(* app/payments/charge_svc/bin/dune *)
let ws_svc_bin_dune = {tpl|(executable
 (name main)
 (libraries
  {{name}}_payments_charge_svc
  sun_svc kafka_eio_service obs_eio obs_eio_loki obs_eio_prometheus
  sun_storage caqti-eio caqti-eio.unix caqti-driver-postgresql
  eio_main))
|tpl}

(* app/comms/notify_worker/lib/notify_worker.ml — satisfies Worker.WORKER *)
let ws_worker_ml = {tpl|(* Inject pool and observability handle via functor so there's no mutable state.
   Worker.Make requires module Message, group_id, and handle inside the functor. *)
module Make (Config : sig
  val pool : Db.pool option
  val ot   : Obs.t
end) = struct

  module Message = Charged

  let group_id = "{{name}}-comms-notify-worker"

  let handle (msg : Message.t) ~ack ~trace_ctx:_ =
    Obs.log_t Config.ot Obs.Info
      ~fields:[("charge_id", msg.id); ("customer_id", msg.customer_id);
               ("amount_cents", string_of_int msg.amount_cents)]
      "charge event received";
    match Config.pool with
    | None -> ack (); Ok ()
    | Some pool ->
      (match Notification.insert pool
              ~charge_id:msg.id ~customer_id:msg.customer_id
              ~amount_cents:msg.amount_cents ~currency:msg.currency with
       | Ok ()   -> ack (); Ok ()
       | Error e ->
         Obs.log_t Config.ot Obs.Error
           ~fields:[("error", Storage_error.to_string e)]
           "db insert failed";
         Error (Storage_error.to_string e))

end
|tpl}

(* app/comms/notify_worker/lib/dune *)
let ws_worker_lib_dune = {tpl|(library
 (name {{name}}_comms_notify)
 (wrapped false)
 (modules Notify_worker)
 (libraries
  {{name}}_storage {{name}}_payments_events
  kafka_eio_service obs_eio sun_storage))
|tpl}

(* app/comms/notify_worker/bin/main.ml *)
let ws_worker_bin_ml = {tpl|let () =
  let postgres_url = Sys.getenv_opt "POSTGRES_URL" in
  let loki_url     = Sys.getenv_opt "LOKI_URL" in
  let kafka_config = Kafka_service.config_of_env () in
  Eio_main.run @@ fun env ->
  let log_backend = match loki_url with
    | None     -> Obs.stdout
    | Some url ->
      Obs_loki.create ~net:env#net ~clock:env#clock ~url
        ~label_names:["service"; "team"] ()
  in
  let prom, _render = Obs_prometheus.create () in
  let ot =
    Obs.with_context
      (Obs.create ~service:"{{name}}-notify-worker" ~mono_clock:env#mono_clock
         ~backend:(Obs.compose log_backend prom))
      [("team", "comms")]
  in
  Eio.Switch.run @@ fun sw ->
  let pool = match postgres_url with
    | None     -> None
    | Some url ->
      (match Db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
       | Error _ -> None
       | Ok p    -> Some p)
  in
  let module W = Notify_worker.Make(struct
    let pool = pool
    let ot   = ot
  end) in
  let module WR = Worker.Make(W) in
  WR.run ~env ~config:kafka_config ~ot ()
|tpl}

(* app/comms/notify_worker/bin/dune *)
let ws_worker_bin_dune = {tpl|(executable
 (name main)
 (libraries
  {{name}}_comms_notify sun_worker kafka_eio_service
  obs_eio obs_eio_loki obs_eio_prometheus
  sun_storage caqti-eio caqti-eio.unix caqti-driver-postgresql
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

(* ── Generic primitive templates ─────────────────────────────────────── *)

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
let svc_bin_ml = {tpl|let () = Eio_main.run @@ fun env ->
  Service.run Handler.routes ~env ()
|tpl}

(* Generic svc: bin/dune *)
let svc_bin_dune = {tpl|(executable
 (name main)
 (libraries {{lib}} sun_svc eio_main))
|tpl}

(* Generic worker: lib/<name>_worker.ml — satisfies Worker.WORKER.
   Replace the stub Message with your actual event module. *)
let worker_lib_ml = {tpl|(* Replace Message with your event module, e.g.:
     module Message = My_team_events.My_event *)
module Message = struct
  type t = { id : string }
  let topic_name = "{{domain}}-{{name}}-events"
  let schema = {|{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}|}
  let encode t = `Assoc [("id", `String t.id)]
  let decode = function
    | `Assoc fields ->
      (match List.assoc_opt "id" fields with
       | Some (`String id) -> Ok { id }
       | _ -> Error "missing id")
    | _ -> Error "expected object"
end

let group_id = "{{domain}}-{{name}}-worker"

let handle (msg : Message.t) ~ack ~trace_ctx:_ =
  Printf.printf "[{{name}}-worker] received id=%s\n%!" msg.id;
  (* Add side effects here. Call ack() only after all side effects succeed.
     Returning Error without acking causes the message to be retried. *)
  ack ();
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
let worker_bin_ml = {tpl|let () = Eio_main.run @@ fun env ->
  let config = Kafka_service.config_of_env () in
  let module W = Worker.Make({{Mod}}) in
  W.run ~env ~config ()
|tpl}

(* Generic worker: bin/dune *)
let worker_bin_dune = {tpl|(executable
 (name main)
 (libraries {{lib}} sun_worker kafka_eio_service eio_main))
|tpl}

(* Generic fn: lib/<name>_fn.ml — satisfies Fn.FN *)
let fn_lib_ml = {tpl|let schedule = "0 * * * *"

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
let fn_bin_ml = {tpl|let () = Eio_main.run @@ fun env ->
  let module F = Fn.Make({{Mod}}) in
  F.run ~env ()
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

let topic_name = "{{team}}-{{name}}s"

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

let decode = function
  | `Assoc fields ->
    let get_s k = match List.assoc_opt k fields with Some (`String s) -> Some s | _ -> None in
    (match get_s "id", get_s "payload" with
     | Some id, Some payload -> Ok { id; payload }
     | _ -> Error "missing required fields")
  | _ -> Error "expected object"
|tpl}

(* ── Command implementations ─────────────────────────────────────────── *)

let new_workspace name =
  let name = norm name in
  if Sys.file_exists name then begin
    Printf.eprintf "error: %S already exists\n" name;
    exit 1
  end;
  Printf.printf "\nScaffolding workspace %S ...\n\n" name;
  let v = [("name", name); ("Name", cap name)] in
  (* root files *)
  write ~path:(name ^ "/.ocamlformat") ~content:tpl_ocamlformat;
  write ~path:(name ^ "/dune-project") ~content:tpl_dune_project;
  write ~path:(name ^ "/README.md")    ~content:(subst v tpl_readme);
  write ~path:(name ^ "/.github/workflows/deploy.yml") ~content:(subst v tpl_github_deploy);
  write ~path:(name ^ "/.github/workflows/sun-ci.yml") ~content:(subst v tpl_github_ci);
  (* events *)
  write ~path:(name ^ "/events/payments/charged.ml")       ~content:(subst v ws_charged_ml);
  write ~path:(name ^ "/events/payments/dune")             ~content:(subst v ws_events_dune);
  (* shared storage lib — Notification module used by svc and worker *)
  write ~path:(name ^ "/lib/notification.ml") ~content:(subst v ws_notification_ml);
  write ~path:(name ^ "/lib/dune")            ~content:(subst v ws_storage_dune);
  (* charge-svc *)
  write ~path:(name ^ "/app/payments/charge_svc/lib/handler.ml")  ~content:(subst v ws_svc_handler_ml);
  write ~path:(name ^ "/app/payments/charge_svc/lib/dune")        ~content:(subst v ws_svc_lib_dune);
  write ~path:(name ^ "/app/payments/charge_svc/bin/main.ml")     ~content:(subst v ws_svc_bin_ml);
  write ~path:(name ^ "/app/payments/charge_svc/bin/dune")        ~content:(subst v ws_svc_bin_dune);
  write ~path:(name ^ "/app/payments/charge_svc/sun.toml")        ~content:tpl_sun_toml;
  write ~path:(name ^ "/app/payments/charge_svc/Dockerfile")
    ~content:(subst (v @ [
      ("repo_dir", "app/payments/charge_svc");
      ("binary",   name ^ "-charge-svc");
    ]) tpl_dockerfile);
  (* notify-worker *)
  write ~path:(name ^ "/app/comms/notify_worker/lib/notify_worker.ml") ~content:(subst v ws_worker_ml);
  write ~path:(name ^ "/app/comms/notify_worker/lib/dune")             ~content:(subst v ws_worker_lib_dune);
  write ~path:(name ^ "/app/comms/notify_worker/bin/main.ml")          ~content:(subst v ws_worker_bin_ml);
  write ~path:(name ^ "/app/comms/notify_worker/bin/dune")             ~content:(subst v ws_worker_bin_dune);
  write ~path:(name ^ "/app/comms/notify_worker/sun.toml")             ~content:tpl_sun_toml;
  write ~path:(name ^ "/app/comms/notify_worker/Dockerfile")
    ~content:(subst (v @ [
      ("repo_dir", "app/comms/notify_worker");
      ("binary",   name ^ "-notify-worker");
    ]) tpl_dockerfile);
  (* db *)
  write ~path:(name ^ "/db/migrations/0001_notifications.sql") ~content:(subst v ws_migration_sql);
  write ~path:(name ^ "/db/migrations/0001_notifications.down.sql") ~content:(subst v ws_migration_down_sql);
  let linked = link_sun_sources name in
  Printf.printf {|
Done. 23 files generated.

  cd %s
  eval $(opam env) && dune build   # verify the scaffold compiles
  sun dev up           # provision local k3d cluster + infra (first time ~5 min)
  sun up               # build images, push, deploy  (~1 min after first run)
  sun migrate                          # apply DB migrations
  sun status           # check pods + see port-forward hint for charge-svc

  CI/CD: set REGISTRY + REGISTRY_USER + REGISTRY_PASSWORD secrets in GitHub, then
         push to main — .github/workflows/sun-ci.yml handles build/test/deploy.
|} name;
  if not linked then
    Printf.printf {|
NOTE: Sun framework source not found — vendor/ links were not created.
  Set SUN_HOME to your Sun checkout and re-run sun new workspace, or
  create the links manually:

    export SUN_HOME=/path/to/sun
    ln -sf $SUN_HOME/framework %s/vendor/framework
    ln -sf $SUN_HOME/integrations %s/vendor/integrations

  Without these links, dune build will fail with "Library not found".
|} name name

let parse_domain_name arg =
  match String.split_on_char '/' arg with
  | [domain; name] -> (norm domain, norm name)
  | _ ->
    Printf.eprintf "error: expected domain/name (e.g. payments/charge), got %S\n" arg;
    exit 1

let ws_of_cwd () = norm (Filename.basename (Sys.getcwd ()))

let new_svc arg =
  let ws = ws_of_cwd () in
  let domain, name = parse_domain_name arg in
  let dir      = Printf.sprintf "app/%s/%s_svc" domain name in
  let repo_dir = dir in
  let lib      = Printf.sprintf "%s_%s_%s_svc" ws domain name in
  let v = [("lib", lib); ("dir", dir); ("repo_dir", repo_dir);
           ("name", name); ("domain", domain); ("binary", name ^ "-svc")] in
  Printf.printf "\nScaffolding svc %s/%s_svc ...\n\n" domain name;
  write ~path:(dir ^ "/lib/handler.ml") ~content:svc_handler_ml;
  write ~path:(dir ^ "/lib/dune")       ~content:(subst v svc_lib_dune);
  write ~path:(dir ^ "/bin/main.ml")    ~content:svc_bin_ml;
  write ~path:(dir ^ "/bin/dune")       ~content:(subst v svc_bin_dune);
  write ~path:(dir ^ "/sun.toml")       ~content:tpl_sun_toml;
  write ~path:(dir ^ "/Dockerfile")     ~content:(subst v tpl_dockerfile);
  Printf.printf "\nDone.  Build: dune build %s/bin/main.exe\n" dir

let new_worker arg =
  let ws = ws_of_cwd () in
  let domain, name = parse_domain_name arg in
  let dir      = Printf.sprintf "app/%s/%s_worker" domain name in
  let repo_dir = dir in
  let lib      = Printf.sprintf "%s_%s_%s_worker" ws domain name in
  let mod_     = cap name ^ "_worker" in
  let v = [("lib", lib); ("dir", dir); ("repo_dir", repo_dir);
           ("name", name); ("domain", domain); ("Mod", mod_);
           ("binary", name ^ "-worker")] in
  Printf.printf "\nScaffolding worker %s/%s_worker ...\n\n" domain name;
  write ~path:(dir ^ "/lib/" ^ (norm name) ^ "_worker.ml") ~content:(subst v worker_lib_ml);
  write ~path:(dir ^ "/lib/dune")    ~content:(subst v worker_lib_dune);
  write ~path:(dir ^ "/bin/main.ml") ~content:(subst v worker_bin_ml);
  write ~path:(dir ^ "/bin/dune")    ~content:(subst v worker_bin_dune);
  write ~path:(dir ^ "/sun.toml")    ~content:tpl_sun_toml;
  write ~path:(dir ^ "/Dockerfile")  ~content:(subst v tpl_dockerfile);
  Printf.printf "\nDone.  Replace the stub Message module with your event module, then:\n";
  Printf.printf "  dune build %s/bin/main.exe\n" dir

let new_fn arg =
  let ws = ws_of_cwd () in
  let domain, name = parse_domain_name arg in
  let dir      = Printf.sprintf "app/%s/%s_fn" domain name in
  let repo_dir = dir in
  let lib      = Printf.sprintf "%s_%s_%s_fn" ws domain name in
  let mod_     = cap name ^ "_fn" in
  let v = [("lib", lib); ("dir", dir); ("repo_dir", repo_dir);
           ("name", name); ("domain", domain); ("Mod", mod_);
           ("binary", name ^ "-fn")] in
  Printf.printf "\nScaffolding fn %s/%s_fn ...\n\n" domain name;
  write ~path:(dir ^ "/lib/" ^ (norm name) ^ "_fn.ml") ~content:(subst v fn_lib_ml);
  write ~path:(dir ^ "/lib/dune")    ~content:(subst v fn_lib_dune);
  write ~path:(dir ^ "/bin/main.ml") ~content:(subst v fn_bin_ml);
  write ~path:(dir ^ "/bin/dune")    ~content:(subst v fn_bin_dune);
  write ~path:(dir ^ "/sun.toml")    ~content:tpl_sun_toml;
  write ~path:(dir ^ "/Dockerfile")  ~content:(subst v tpl_dockerfile);
  Printf.printf "\nDone.  Build: dune build %s/bin/main.exe\n" dir

let new_event arg =
  let ws = ws_of_cwd () in
  let team, name = parse_domain_name arg in
  let file    = Printf.sprintf "events/%s/%s.ml" team name in
  let dune_f  = Printf.sprintf "events/%s/dune"  team in
  let mod_    = cap name in
  let lib     = ws ^ "_" ^ team ^ "_events" in
  let v = [("team", team); ("name", name); ("Mod", mod_); ("lib", lib)] in
  Printf.printf "\nScaffolding event %s/%s ...\n\n" team name;
  if Sys.file_exists file then begin
    Printf.eprintf "error: %S already exists\n" file;
    exit 1
  end;
  write ~path:file ~content:(subst v event_ml);
  if Sys.file_exists dune_f then
    Printf.printf {|
  Note: %s already exists.
  Add %s to the (modules ...) list.
|} dune_f mod_
  else begin
    write ~path:dune_f ~content:(subst v {tpl|(library
 (name {{lib}})
 (wrapped false)
 (modules {{Mod}})
 (libraries kafka_eio_service yojson))
|tpl});
  end;
  Printf.printf "\nDone.  Consumers add (libraries %s) to their dune files.\n" lib

(* ── Cmdliner terms ──────────────────────────────────────────────────── *)

let name_arg docv doc =
  Arg.(required & pos 0 (some string) None & info [] ~docv ~doc)

let workspace_cmd =
  Cmd.v
    (Cmd.info "workspace" ~doc:"Scaffold a new Sun workspace with a working two-service example")
    Term.(const new_workspace $ name_arg "NAME" "Workspace name, e.g. acme")

let svc_cmd =
  Cmd.v
    (Cmd.info "svc" ~doc:"Add an HTTP service to the current workspace")
    Term.(const new_svc $ name_arg "DOMAIN/NAME" "e.g. payments/charge")

let worker_cmd =
  Cmd.v
    (Cmd.info "worker" ~doc:"Add a Kafka consumer worker to the current workspace")
    Term.(const new_worker $ name_arg "DOMAIN/NAME" "e.g. comms/notify")

let fn_cmd =
  Cmd.v
    (Cmd.info "fn" ~doc:"Add a scheduled function to the current workspace")
    Term.(const new_fn $ name_arg "DOMAIN/NAME" "e.g. billing/monthly_report")

let event_cmd =
  Cmd.v
    (Cmd.info "event" ~doc:"Add a typed Kafka event contract to the current workspace")
    Term.(const new_event $ name_arg "TEAM/NAME" "e.g. payments/charged")

let cmd =
  Cmd.group
    (Cmd.info "new" ~doc:"Scaffold workspace components")
    [ workspace_cmd; svc_cmd; worker_cmd; fn_cmd; event_cmd ]
