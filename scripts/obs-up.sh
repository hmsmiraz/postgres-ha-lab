#!/usr/bin/env bash
# Deploy the observability stage A (Prometheus, kube-state-metrics, Grafana) into pg-ha.
# Images are used by name:tag because the digest form cannot resolve in the kind nodes (see docs/known-limitations.md).
# Safe to run again. It deletes nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source versions.env

P="${PROMETHEUS_IMAGE%%@*}"
K="${KSM_IMAGE%%@*}"
G="${GRAFANA_IMAGE%%@*}"
for i in "$P" "$K" "$G"; do kind load docker-image "$i" --name kind; done

kubectl apply -f k8s/pg/00-namespace.yaml
bash scripts/gen-grafana-secret.sh
kubectl apply -f k8s/obs/10-rbac.yaml
sed "s|__PROMETHEUS_IMAGE__|${P}|g" k8s/obs/20-prometheus.yaml | kubectl apply -f -
sed "s|__KSM_IMAGE__|${K}|g" k8s/obs/30-ksm.yaml | kubectl apply -f -
sed "s|__GRAFANA_IMAGE__|${G}|g" k8s/obs/40-grafana.yaml | kubectl apply -f -
kubectl -n pg-ha rollout status deploy/prometheus --timeout=300s
kubectl -n pg-ha rollout status deploy/kube-state-metrics --timeout=300s
kubectl -n pg-ha rollout status deploy/grafana --timeout=300s
