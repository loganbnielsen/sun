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
