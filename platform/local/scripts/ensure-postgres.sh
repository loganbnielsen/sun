#!/usr/bin/env bash
set -euo pipefail

CONTAINER="sun-postgres"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-dev}"
POSTGRES_DB="${POSTGRES_DB:-sun_dev}"
PORT="${POSTGRES_PORT:-5432}"

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "Postgres already running (container: ${CONTAINER})"
else
  echo "Starting Postgres..."
  docker run -d \
    --name "${CONTAINER}" \
    --rm \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    -e POSTGRES_DB="${POSTGRES_DB}" \
    -p "${PORT}:5432" \
    postgres:16-alpine \
    > /dev/null
fi

echo "Waiting for port ${PORT} ready."
for i in $(seq 1 30); do
  if nc -z localhost "${PORT}" 2>/dev/null; then break; fi
  sleep 0.5
done

# Wait for Postgres to accept connections
for i in $(seq 1 20); do
  if docker exec "${CONTAINER}" pg_isready -q 2>/dev/null; then break; fi
  sleep 0.5
done

echo "Postgres ready at localhost:${PORT}"
echo "  URL: postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PORT}/${POSTGRES_DB}"
echo ""
echo "  export POSTGRES_URL=postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PORT}/${POSTGRES_DB}"
