#!/usr/bin/env bash
# Deploy sun demo to local k3s cluster.
# Requires: k3s running, librdkafka-dev installed, dune build passing.
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

echo "=== Deploying sun to local k3s ==="

# Apply namespace first
kubectl apply -f k8s/namespace.yaml

# Deploy Redpanda
echo "Deploying Redpanda..."
kubectl apply -f k8s/redpanda.yaml
kubectl -n sun rollout status statefulset/redpanda --timeout=120s

# Build and import demo image into k3s
echo "Building sun-demo image..."
docker build -t sun-demo:local -f Dockerfile ..
echo "Importing image into k3s..."
docker save sun-demo:local | sudo k3s ctr images import -

# Deploy demo app
echo "Deploying sun-demo..."
kubectl apply -f k8s/demo-app.yaml
kubectl -n sun rollout status deployment/sun-demo --timeout=60s

echo ""
echo "=== Deployed ==="
kubectl -n sun get pods
echo ""
echo "Logs: kubectl -n sun logs -f deployment/sun-demo"
echo "Exec: kubectl -n sun exec -it deployment/sun-demo -- sh"
