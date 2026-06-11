#!/usr/bin/env bash
# Create the topics used by sun tests and demo.
set -euo pipefail

BROKERS="${KAFKA_BROKERS:-localhost:9092}"

topics=(
  "sun-demo"
  "sun-producer-test"
  "sun-consumer-test"
)

for topic in "${topics[@]}"; do
  echo "Creating topic: $topic"
  rpk topic create "$topic" \
    --brokers "$BROKERS" \
    --partitions 3 \
    --replicas 1 \
    2>&1 | grep -v "TOPIC_ALREADY_EXISTS" || true
done

echo "Topics:"
rpk topic list --brokers "$BROKERS"
