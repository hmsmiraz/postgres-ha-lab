#!/usr/bin/env bash
# Deploy the Patroni PostgreSQL cluster into the kind cluster.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source versions.env

IMG="${IMAGE_NAME}:${IMAGE_TAG}"
kind load docker-image "$IMG" --name kind

kubectl apply -f k8s/pg/00-namespace.yaml
bash scripts/gen-secrets.sh
bash scripts/gen-objstore-secrets.sh
bash scripts/gen-pgbackrest-tls.sh
kubectl apply -f k8s/pg/10-rbac.yaml -f k8s/pg/20-config.yaml \
              -f k8s/pg/25-pgbackrest.yaml -f k8s/pg/30-services.yaml -f k8s/pg/40-pdb.yaml
sed "s|__IMAGE__|${IMG}|g" k8s/pg/50-statefulset.yaml | kubectl apply -f -
kubectl -n pg-ha rollout status sts/pg-ha --timeout=600s
