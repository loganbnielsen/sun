#!/usr/bin/env bash
# Sun golden-path e2e test harness
#
# Exercises the product-critical user journey end-to-end:
#   1. Build the sun binary
#   2. Scaffold a fresh workspace with `sun new workspace`
#   3. Build the workspace
#   4. Deploy with `sun up`
#   5. Run migrations with `sun migrate`
#   6. Assert `sun status` reports the deployed service
#   7. Curl /health
#   8. POST /charges
#   9. Poll /notifications until the Kafka→worker→Postgres flow is visible
#  10. Tear down port-forwards and temp workspace
#
# Prerequisites (must already be running):
#   - k3d cluster "sun-local" (sun dev up)
#   - Redpanda/Kafka at localhost:9092
#   - PostgreSQL at localhost:5432 (forwarded by sun dev up)
#   - Loki at localhost:3100 (optional — skipped if absent)
#
# Usage:
#   bash cli/sun/e2e/golden_path.sh               # run from repo root
#   SUN_BINARY=/path/to/sun bash cli/sun/e2e/golden_path.sh
#   SUN_BINARY=... SKIP_BUILD=1 bash cli/sun/e2e/golden_path.sh
#
# Exit codes:
#   0  all assertions passed
#   1  setup failure (infra missing, build broken, scaffold failed)
#   2  assertion failure (health, charge, or notification check failed)

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
pass()   { echo -e "${GREEN}[PASS]${NC} $*"; }
fail()   { echo -e "${RED}[FAIL]${NC} $*"; }
info()   { echo -e "${DIM}[ >> ]${NC} $*"; }
header() { echo -e "\n${BOLD}── $* ──${NC}"; }
die()    { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

SUN_BINARY="${SUN_BINARY:-$REPO_ROOT/_build/default/cli/sun/bin/main.exe}"
SKIP_BUILD="${SKIP_BUILD:-0}"
# Unique workspace name using timestamp + PID to avoid clashing with existing
# sun dev up or other test runs sharing the local substrate.
WS_NAME="golden${$}"
WORK_DIR=""

# ── Assertion counters ────────────────────────────────────────────────────
FAILS=0
check() {
  local label="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = "true" ] || [ "$ok" = "0" ]; then
    pass "$label"
  else
    fail "$label${detail:+ — $detail}"
    FAILS=$((FAILS + 1))
  fi
}

# ── Cleanup trap ──────────────────────────────────────────────────────────
CLEANUP_DONE=0
cleanup() {
  [ $CLEANUP_DONE -eq 1 ] && return
  CLEANUP_DONE=1
  header "Cleanup"

  # Kill any port-forward we started (tracked by pid file)
  if [ -n "${PF_PID:-}" ] && kill -0 "$PF_PID" 2>/dev/null; then
    info "killing port-forward (pid $PF_PID)"
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi

  # Remove temp workspace directory
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    info "removing temp workspace $WORK_DIR"
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT INT TERM

# ── Stage 1: build sun binary ─────────────────────────────────────────────
header "Stage 1: sun binary"

if [ "$SKIP_BUILD" = "1" ]; then
  info "SKIP_BUILD=1 — skipping dune build"
else
  info "building sun binary (eval \$(opam env) && dune build cli/sun/)"
  cd "$REPO_ROOT"
  eval "$(opam env)" || die "opam env failed — is opam installed?"
  dune build cli/sun/ 2>&1 || die "dune build failed"
fi

[ -f "$SUN_BINARY" ] || die "sun binary not found at $SUN_BINARY"
info "using sun binary: $SUN_BINARY"
pass "sun binary ready"

# ── Stage 2: infra pre-flight ─────────────────────────────────────────────
header "Stage 2: infra pre-flight"

# k3d cluster
if ! kubectl get nodes >/dev/null 2>&1; then
  die "kubectl cannot reach any cluster. Run 'sun dev up' first."
fi
info "k3d cluster reachable"

# Redpanda / Kafka
if ! nc -z localhost 9092 2>/dev/null; then
  die "Kafka not reachable at localhost:9092. Run 'sun dev up' first."
fi
info "Kafka reachable at localhost:9092"

# PostgreSQL (via sun dev up port-forward at 5432)
if ! nc -z localhost 5432 2>/dev/null; then
  die "PostgreSQL not reachable at localhost:5432. Run 'sun dev up' first."
fi
info "PostgreSQL reachable at localhost:5432"
pass "infra pre-flight passed"

# ── Stage 3: scaffold workspace ────────────────────────────────────────────
header "Stage 3: sun new workspace $WS_NAME"

WORK_DIR="$(mktemp -d /tmp/sun-golden-XXXXXX)"
cd "$WORK_DIR"

# sun new workspace creates the directory inside cwd
"$SUN_BINARY" new workspace "$WS_NAME" 2>&1 || die "sun new workspace failed"
[ -d "$WS_NAME" ] || die "sun new workspace did not create directory $WS_NAME"
cd "$WS_NAME"
pass "workspace scaffolded at $WORK_DIR/$WS_NAME"

# ── Stage 4: build workspace ───────────────────────────────────────────────
header "Stage 4: dune build (workspace)"

eval "$(opam env)"
dune build 2>&1 || die "workspace dune build failed — scaffold template may be broken"
pass "workspace builds clean"

# ── Stage 5: sun up ───────────────────────────────────────────────────────
header "Stage 5: sun up"

# We need a local port for this workspace's charge-svc. sun up hardcodes 8080
# but we may be sharing the substrate with other workspaces. We port-forward
# explicitly on a unique port to avoid conflicts with other test runs or dev
# workspaces. We let sun up deploy the resources and then manage the
# port-forward ourselves.

# Build the image inside the local k3d registry
SUN_PORT=18080   # unique port to avoid conflicts with dev workspace on 8080

KAFKA_BROKERS=localhost:9092 \
POSTGRES_URL=postgresql://postgres:dev@localhost:5432/dev \
  "$SUN_BINARY" up 2>&1 || die "sun up failed"
pass "sun up completed"

# ── Stage 6: determine namespace + start explicit port-forward ────────────
header "Stage 6: start port-forward"

# Namespace derives from workspace name + domain ("payments")
# sun_cli_deployment_plan.namespace_of produces "<ws-k8sname>-<domain-k8sname>"
# k8s_name_of lowercases and replaces [^a-z0-9] with '-'
ws_k8s="$(echo "$WS_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-*$//')"
NS="${ws_k8s}-payments"
SVC="charge-svc"

info "namespace: $NS  service: $SVC  local port: $SUN_PORT"

# Wait for the namespace to exist (sun up may still be propagating)
DEADLINE=$((SECONDS + 60))
until kubectl get ns "$NS" >/dev/null 2>&1 || [ $SECONDS -ge $DEADLINE ]; do
  info "waiting for namespace $NS ..."; sleep 2
done
kubectl get ns "$NS" >/dev/null 2>&1 || die "namespace $NS did not appear within 60s"

# Wait for the charge-svc pod to be Ready
info "waiting for $SVC pods to be Running in $NS (up to 120s) ..."
kubectl wait --for=condition=Available deployment --all -n "$NS" --timeout=120s 2>&1 || true
# Fallback: wait for at least one running pod
DEADLINE=$((SECONDS + 120))
until kubectl get pods -n "$NS" -l app="$SVC" --no-headers 2>/dev/null | grep -q "Running" \
    || [ $SECONDS -ge $DEADLINE ]; do
  info "waiting for Running pod ..."; sleep 3
done
kubectl get pods -n "$NS" -l app="$SVC" --no-headers 2>/dev/null | grep -q "Running" \
  || die "charge-svc pod did not reach Running state in $NS within 120s"

# Start our own port-forward in the background on $SUN_PORT
kubectl port-forward -n "$NS" svc/"$SVC" "${SUN_PORT}:80" </dev/null >/tmp/sun-golden-pf.log 2>&1 &
PF_PID=$!
info "port-forward started (pid $PF_PID) localhost:$SUN_PORT → $NS/svc/$SVC:80"

# Wait for port-forward to accept connections (up to 10s)
DEADLINE=$((SECONDS + 10))
until nc -z localhost "$SUN_PORT" 2>/dev/null || [ $SECONDS -ge $DEADLINE ]; do
  sleep 0.5
done
nc -z localhost "$SUN_PORT" 2>/dev/null || die "port-forward did not become ready within 10s"
pass "port-forward ready at localhost:$SUN_PORT"

# ── Stage 7: sun migrate ──────────────────────────────────────────────────
header "Stage 7: sun migrate"

POSTGRES_URL=postgresql://postgres:dev@localhost:5432/dev \
  "$SUN_BINARY" migrate 2>&1 || die "sun migrate failed"
pass "sun migrate completed"

# ── Stage 8: sun status ───────────────────────────────────────────────────
header "Stage 8: sun status"

STATUS_OUT="$("$SUN_BINARY" status 2>&1)"
echo "$STATUS_OUT"

# status should mention the namespace or the svc name
if echo "$STATUS_OUT" | grep -qi "$NS\|$SVC\|Running"; then
  check "sun status mentions deployed service" true
else
  check "sun status mentions deployed service" false \
    "output did not contain $NS, $SVC, or 'Running'"
fi

# ── Stage 9: /health ──────────────────────────────────────────────────────
header "Stage 9: GET /health"

HEALTH_OUT="$(curl -sf "http://localhost:${SUN_PORT}/health" 2>&1)" \
  || { HEALTH_OUT="(curl failed with exit $?)"; }
info "response: $HEALTH_OUT"

if echo "$HEALTH_OUT" | grep -qi "ok\|healthy\|true"; then
  check "GET /health returns ok" true
else
  check "GET /health returns ok" false "got: $HEALTH_OUT"
  echo ""
  fail "Health check failed — remaining stages skipped."
  exit 2
fi

# ── Stage 10: POST /charges ───────────────────────────────────────────────
header "Stage 10: POST /charges"

CHARGE_ID="cus_golden_e2e"
CHARGE_BODY='{"customer_id":"'"$CHARGE_ID"'","amount_cents":999,"currency":"usd"}'
CHARGE_HTTP_CODE="$(curl -s -o /tmp/sun-golden-charge.json -w '%{http_code}' \
  -X POST "http://localhost:${SUN_PORT}/charges" \
  -H 'Content-Type: application/json' \
  -d "$CHARGE_BODY" 2>&1)"
CHARGE_RESP="$(cat /tmp/sun-golden-charge.json 2>/dev/null || echo '')"
info "HTTP $CHARGE_HTTP_CODE — $CHARGE_RESP"

check "POST /charges returns 2xx" \
  "$([ "${CHARGE_HTTP_CODE:-0}" -ge 200 ] && [ "${CHARGE_HTTP_CODE:-0}" -lt 300 ] && echo true || echo false)" \
  "HTTP $CHARGE_HTTP_CODE"

# ── Stage 11: poll /notifications ────────────────────────────────────────
header "Stage 11: poll /notifications (up to 30s)"

FOUND=false
DEADLINE=$((SECONDS + 30))
while [ $SECONDS -lt $DEADLINE ]; do
  NOTIF_OUT="$(curl -sf "http://localhost:${SUN_PORT}/notifications" 2>/dev/null || echo '[]')"
  if echo "$NOTIF_OUT" | grep -q "$CHARGE_ID"; then
    FOUND=true
    break
  fi
  info "notifications not yet visible — retrying in 2s ..."
  sleep 2
done

info "final /notifications response: $NOTIF_OUT"

if [ "$FOUND" = "true" ]; then
  check "notification for $CHARGE_ID visible in /notifications" true
else
  check "notification for $CHARGE_ID visible in /notifications" false \
    "timed out after 30s; last response: ${NOTIF_OUT:-empty}"
fi

# ── Summary ───────────────────────────────────────────────────────────────
header "Summary"
if [ $FAILS -eq 0 ]; then
  pass "All golden-path assertions passed."
  exit 0
else
  fail "$FAILS assertion(s) failed."
  exit 2
fi
