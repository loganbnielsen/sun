# Pluto

A Sun workspace with two services: `charge_svc` (HTTP) and `notify_worker` (Kafka consumer).

## Prerequisites

System packages required before building:

```bash
sudo apt-get install -y librdkafka-dev libpq-dev libpq5
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
```
