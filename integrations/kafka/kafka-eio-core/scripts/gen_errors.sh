#!/usr/bin/env bash
# Scrapes rd_kafka_resp_err_t from rdkafka.h and regenerates the error variant list.
# Usage: gen_errors.sh /path/to/rdkafka.h
set -euo pipefail

HEADER="${1:-/usr/include/librdkafka/rdkafka.h}"

echo "(* Auto-generated from $HEADER — do not edit by hand *)"
echo "(* Run: scripts/gen_errors.sh /path/to/rdkafka.h > lib/kafka_error_variants.ml.inc *)"
echo ""

grep -E '^\s+RD_KAFKA_RESP_ERR_' "$HEADER" \
  | grep -v '/\*' \
  | sed 's/^\s*//' \
  | awk -F'[= ,]' '{
      name=$1
      # strip prefix
      gsub(/^RD_KAFKA_RESP_ERR_/, "", name)
      gsub(/^__/, "", name)
      # title-case
      n = split(name, parts, "_")
      result = ""
      for (i=1; i<=n; i++) {
        word = tolower(parts[i])
        result = result substr(toupper(word),1,1) substr(word,2)
        if (i < n) result = result "_"
      }
      print "  | " result
    }'
