# Pluto

A Sun workspace with two services: `charge_svc` (HTTP) and `notify_worker` (Kafka consumer).

## Build

```bash
eval $(opam env)
dune build
```

## Run locally

```bash
# Start Kafka (Redpanda)
bash <path-to-sun>/platform/local/scripts/ensure-broker.sh

# Run the worker
KAFKA_BROKERS=localhost:9092 dune exec app/comms/notify_worker/bin/main.exe

# In another terminal, run the service
dune exec app/payments/charge_svc/bin/main.exe
```

## CLI commands

```bash
sun dev up        # provision local k3d cluster + infra
sun up            # build images and deploy to cluster
sun status        # show running pods and endpoints
sun migrate       # apply database migrations
```

## Project layout

```
events/payments/          ← Charged event contract (payments team owns)
app/payments/charge_svc/  ← HTTP service (publishes Charged on POST /charges)
app/comms/notify_worker/  ← Kafka consumer (subscribes to Charged)
db/migrations/            ← SQL migration files
```
