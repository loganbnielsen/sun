.PHONY: build test test-unit test-integration schema-check broker-up

KAFKA_BROKERS ?= localhost:9092
SCHEMA_REGISTRY_URL ?= http://localhost:8081

DEPLOY_SCRIPTS := ../../platform/deploy/scripts

build:
	dune build

# Unit tests only — no broker required.
test-unit:
	dune test kafka-eio-core/test/ \
	          kafka-eio-service/test/test_kafka_service.exe

# Full integration test suite — requires Redpanda running.
test-integration: broker-up
	KAFKA_BROKERS=$(KAFKA_BROKERS) \
	SCHEMA_REGISTRY_URL=$(SCHEMA_REGISTRY_URL) \
	dune test

# Schema compatibility checks only — requires schema registry running.
# Convention: run this before pushing to catch breaking schema changes.
# Each service/worker should have a test_schemas.ml following this same pattern.
schema-check: broker-up
	KAFKA_BROKERS=$(KAFKA_BROKERS) \
	SCHEMA_REGISTRY_URL=$(SCHEMA_REGISTRY_URL) \
	dune exec kafka-eio-service/test/test_kafka_service_integration.exe -- test "schema_check"

# Default: unit tests (safe to run anywhere, no broker needed).
test: test-unit

broker-up:
	$(DEPLOY_SCRIPTS)/ensure-broker.sh
