#!/usr/bin/env bash
# Sun test runner — executes all test suites, enforces per-suite timeouts,
# and fails on performance regressions against a committed baseline.
#
# Usage:
#   ./platform/local/scripts/run_tests.sh                    # full run
#   ./platform/local/scripts/run_tests.sh --update-baseline  # run and record timings as new baseline
#   ./platform/local/scripts/run_tests.sh --no-infra         # skip infra setup (already running)
#   ./platform/local/scripts/run_tests.sh unit kafka         # run specific suites only
#   ./platform/local/scripts/run_tests.sh golden-e2e         # golden-path only (scaffold→deploy→curl)
#
# Suites:
#   unit          OCaml unit tests (no infrastructure required)
#   kafka         Kafka integration tests (broker required)
#   observability Observability integration tests (Loki required)
#   storage       Storage integration tests (Postgres required)
#   e2e           Full-stack demo binary (Kafka + Loki + Postgres)
#   golden-e2e    Golden-path harness: scaffold → sun up → sun migrate →
#                 /health → POST /charges → poll /notifications
#                 (k3d cluster + full infra required; opt-in, not run by default)
#
# Exit codes:
#   0  all suites passed, no regression
#   1  one or more suites failed or timed out
#   2  performance regression (>1.2× slower than baseline)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export REPO_ROOT
BASELINE="$REPO_ROOT/tools/perf/perf_baseline.json"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
pass()  { echo -e "${GREEN}✓${NC} $*"; }
fail()  { echo -e "${RED}✗${NC} $*"; }
info()  { echo -e "${DIM}→${NC} $*"; }
header(){ echo -e "\n${BOLD}$*${NC}"; }

# ── Per-suite timeouts (seconds) ──────────────────────────────────────────────
declare -A TIMEOUTS=(
  [unit]=60
  [kafka]=120
  [observability]=90
  [storage]=90
  [e2e]=180
  [golden-e2e]=600
)

# ── Regression threshold ──────────────────────────────────────────────────────
# Hard fail if a suite runs >1.2× slower than its baseline. 10% variance is
# plausible from system load; 20% is unambiguously a regression.
FAIL_RATIO=1.2

# ── Flags ────────────────────────────────────────────────────────────────────
UPDATE_BASELINE=0
SKIP_INFRA=0
REQUESTED_SUITES=()

for arg in "$@"; do
  case "$arg" in
    --update-baseline) UPDATE_BASELINE=1 ;;
    --no-infra)        SKIP_INFRA=1 ;;
    unit|kafka|observability|storage|e2e|golden-e2e) REQUESTED_SUITES+=("$arg") ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# golden-e2e is opt-in (requires a full k3d cluster + full infra) and is
# excluded from the default all-suites run.  Pass it explicitly to invoke it.
ALL_SUITES=(unit kafka observability storage e2e)
SUITES=("${REQUESTED_SUITES[@]:-${ALL_SUITES[@]}}")

# ── Timing ────────────────────────────────────────────────────────────────────
now_ms()    { date +%s%3N; }
elapsed_s() { awk "BEGIN { printf \"%.3f\", ($2 - $1) / 1000 }"; }

# ── Baseline I/O (requires jq) ────────────────────────────────────────────────
HAS_JQ=0
command -v jq &>/dev/null && HAS_JQ=1

# Returns the duration_s from the most recent baseline:true entry, or "null".
baseline_get() {
  [ $HAS_JQ -eq 0 ] && echo "null" && return
  jq -r ".suites.$1.history | map(select(.baseline == true)) | last | .duration_s // \"null\"" "$BASELINE"
}

# Appends an entry to the history array. Pass baseline=true when --update-baseline.
baseline_append() {
  local suite=$1 duration_s=$2 is_baseline=$3
  [ $HAS_JQ -eq 0 ] && return
  local today; today=$(date +%Y-%m-%d)
  local commit; commit=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  local entry
  if [ "$is_baseline" = "true" ]; then
    entry="{\"date\":\"$today\",\"commit\":\"$commit\",\"duration_s\":$duration_s,\"baseline\":true}"
  else
    entry="{\"date\":\"$today\",\"commit\":\"$commit\",\"duration_s\":$duration_s}"
  fi
  local tmp; tmp=$(mktemp)
  jq ".suites.${suite}.history += [$entry]" "$BASELINE" > "$tmp"
  mv "$tmp" "$BASELINE"
}

# ── Regression check ──────────────────────────────────────────────────────────
check_regression() {
  local suite=$1 actual_s=$2
  local base; base=$(baseline_get "$suite")
  [ "$base" = "null" ] && return 0   # no baseline yet

  local threshold
  threshold=$(awk "BEGIN { printf \"%.2f\", $base * $FAIL_RATIO }")

  if awk "BEGIN { exit !($actual_s >= $threshold) }"; then
    local ratio; ratio=$(awk "BEGIN { printf \"%.2f\", $actual_s / $base }")
    fail "$suite: ${actual_s}s vs baseline ${base}s (${ratio}× — regression)"
    return 1
  fi
  return 0
}

# ── Suite runners ─────────────────────────────────────────────────────────────
run_unit() {
  info "Primitives + observability unit tests (no infrastructure required)"
  eval $(opam env)
  dune test framework/ integrations/observability/obs-eio/test/ cli/sun/test/ --force 2>&1
}

run_kafka() {
  info "Kafka integration tests (requires broker at localhost:9092)"
  eval $(opam env)
  KAFKA_BROKERS=localhost:9092 dune test integrations/kafka/ --force 2>&1
}

run_observability() {
  info "Observability integration tests (requires Loki at localhost:3100)"
  eval $(opam env)
  LOKI_URL=http://localhost:3100 dune test integrations/observability/ --force 2>&1
}

run_storage() {
  info "Storage integration tests (requires Postgres at localhost:5432)"
  eval $(opam env)
  POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sun_dev \
    dune test integrations/storage/ --force 2>&1
}

run_e2e() {
  info "End-to-end demo: charge_svc → Kafka → notify_worker → Postgres"
  eval $(opam env)
  KAFKA_BROKERS=localhost:9092 \
  LOKI_URL=http://localhost:3100 \
  POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sun_dev \
    dune exec examples/local-demo/bin/demo.exe 2>&1
}

run_golden-e2e() {
  info "Golden-path: scaffold → sun up → sun migrate → /health → POST /charges → /notifications"
  info "  Harness: cli/sun/e2e/golden_path.sh"
  info "  Prerequisites: sun dev up (k3d + Kafka + PostgreSQL at dev defaults)"
  bash "$REPO_ROOT/cli/sun/e2e/golden_path.sh" 2>&1
}

# ── Infrastructure setup ──────────────────────────────────────────────────────
ensure_infra() {
  header "Infrastructure"
  local needs_kafka=0 needs_loki=0 needs_postgres=0

  for suite in "${SUITES[@]}"; do
    case "$suite" in
      kafka|e2e) needs_kafka=1; needs_loki=1; needs_postgres=1 ;;
      observability) needs_loki=1 ;;
      storage) needs_postgres=1 ;;
      golden-e2e) needs_kafka=1; needs_postgres=1 ;;
    esac
  done

  if [ $needs_kafka    -eq 1 ]; then info "Kafka (Redpanda)";  bash "$SCRIPT_DIR/ensure-broker.sh";  fi
  if [ $needs_loki     -eq 1 ]; then info "Loki";              bash "$SCRIPT_DIR/ensure-loki.sh";    fi
  if [ $needs_postgres -eq 1 ]; then info "PostgreSQL";        bash "$SCRIPT_DIR/ensure-postgres.sh"; fi
}

# ── Result tracking ───────────────────────────────────────────────────────────
declare -A RESULTS   # suite → pass|fail|timeout
declare -A TIMINGS   # suite → elapsed seconds
REGRESSION_FAIL=0

# ── Main loop ─────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Sun test runner${NC}"
echo "Suites: ${SUITES[*]}"
[ $UPDATE_BASELINE -eq 1 ] && echo "Mode: --update-baseline"
[ $HAS_JQ -eq 0 ] && echo -e "${DIM}jq not found — regression checks disabled${NC}"

[ $SKIP_INFRA -eq 0 ] && ensure_infra

header "Suites"

for suite in "${SUITES[@]}"; do
  echo -e "\n  ${BOLD}${suite}${NC}"
  timeout_s=${TIMEOUTS[$suite]}

  start=$(now_ms)
  set +e
  timeout "$timeout_s" bash -c "$(declare -f info pass fail header now_ms elapsed_s "run_${suite}"); run_${suite}" 2>&1 \
    | sed 's/^/    /'
  exit_code=${PIPESTATUS[0]}
  set -e
  end=$(now_ms)

  elapsed=$(elapsed_s "$start" "$end")
  TIMINGS[$suite]=$elapsed

  if [ $exit_code -eq 124 ]; then
    fail "${suite}: timed out after ${timeout_s}s"
    RESULTS[$suite]=timeout
  elif [ $exit_code -ne 0 ]; then
    fail "${suite}: failed (${elapsed}s)"
    RESULTS[$suite]=fail
  else
    RESULTS[$suite]=pass
    pass "${suite}: passed (${elapsed}s)"

    # Regression check
    if ! check_regression "$suite" "$elapsed"; then
      REGRESSION_FAIL=1
    fi

    # Append to history
    if [ $UPDATE_BASELINE -eq 1 ]; then
      baseline_append "$suite" "$elapsed" "true"
    else
      baseline_append "$suite" "$elapsed" "false"
    fi
  fi
done

# ── Summary table ─────────────────────────────────────────────────────────────
header "Summary"
printf "  %-18s %-10s %-10s %-12s\n" "Suite" "Result" "Time" "Baseline"
printf "  %-18s %-10s %-10s %-12s\n" "─────────────────" "──────────" "─────────" "────────────"

ALL_PASSED=1
# Iterate the actually-requested set (may include opt-in suites like golden-e2e
# that are not in ALL_SUITES).
for suite in "${SUITES[@]}"; do

  result=${RESULTS[$suite]}
  elapsed=${TIMINGS[$suite]}
  base=$(baseline_get "$suite")

  case "$result" in
    pass)    result_str="${GREEN}pass${NC}" ;;
    fail)    result_str="${RED}fail${NC}";    ALL_PASSED=0 ;;
    timeout) result_str="${RED}timeout${NC}"; ALL_PASSED=0 ;;
  esac

  [ "$base" = "null" ] && base_str="${DIM}none${NC}" || base_str="${base}s"

  printf "  %-18s " "$suite"
  echo -ne "$result_str"
  printf "%-$((10 - ${#result} + 6))s" ""
  printf "%-10s" "${elapsed}s"
  echo -e "$base_str"
done

if [ $UPDATE_BASELINE -eq 1 ]; then
  echo ""
  pass "Baseline entries recorded in $BASELINE"
fi

# ── Exit ──────────────────────────────────────────────────────────────────────
echo ""
if [ $ALL_PASSED -eq 0 ]; then
  fail "One or more suites failed."
  exit 1
elif [ $REGRESSION_FAIL -eq 1 ]; then
  fail "Performance regression detected (>${FAIL_RATIO}× slower than baseline)."
  exit 2
else
  pass "All suites passed."
  exit 0
fi
