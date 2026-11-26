#!/usr/bin/env bash
# Deploy the in-cluster object store (Garage behind an nginx TLS front) into pg-ha and initialise it.
# Safe to run again: Secrets are kept, the init Job is recreated.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source versions.env

IMG="${IMAGE_NAME}:${IMAGE_TAG}"
kind load docker-image "$IMG" "$OBJSTORE_PROXY_RUNTIME_IMAGE" --name "${KIND_CLUSTER_NAME:-kind}"

kubectl apply -f k8s/pg/00-namespace.yaml
bash scripts/gen-objstore-secrets.sh
kubectl apply -f k8s/objstore/10-config.yaml -f k8s/objstore/20-service.yaml
sed -e "s|__GARAGE_IMAGE__|${OBJSTORE_IMAGE}|g" -e "s|__PROXY_IMAGE__|${OBJSTORE_PROXY_RUNTIME_IMAGE}|g" \
  k8s/objstore/30-statefulset.yaml | kubectl apply -f -
kubectl -n pg-ha rollout status sts/objstore --timeout=300s

kubectl -n pg-ha create configmap objstore-init --from-file=objstore-init.py=scripts/objstore-init.py \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n pg-ha delete job objstore-init --ignore-not-found --wait=true
sed "s|__IMAGE__|${IMG}|g" k8s/objstore/40-init-job.yaml | kubectl apply -f -
kubectl -n pg-ha wait --for=condition=complete job/objstore-init --timeout=300s
