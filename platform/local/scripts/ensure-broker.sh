#!/usr/bin/env bash
# Ensure Redpanda is running and all test topics exist.
# Called automatically before integration tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/start-redpanda.sh"

# Verify the host-side port is accepting connections before creating topics.
# start-redpanda.sh checks internal cluster health via rpk inside the container,
# but the host port binding can lag behind — and the already-running fast-path
# exits immediately with no checks at all.
KAFKA_PORT="${KAFKA_PORT:-9092}"
echo -n "Waiting for port ${KAFKA_PORT}"
for i in $(seq 1 20); do
  if nc -z localhost "${KAFKA_PORT}" > /dev/null 2>&1; then
    echo " ready."
    break
  fi
  echo -n "."
  sleep 1
  if [ "$i" -eq 20 ]; then
    echo ""
    echo "ERROR: port ${KAFKA_PORT} not reachable after 20 seconds." >&2
    exit 1
  fi
done

"${SCRIPT_DIR}/create-topics.sh"
