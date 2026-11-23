#!/usr/bin/env bash
# Open Prometheus (http://localhost:9090) and Grafana (http://localhost:3000) on this PC only.
# Both forwards bind 127.0.0.1. The Grafana admin password is copied to the Windows clipboard and never printed.
set -euo pipefail
NS="${NS:-pg-ha}"
if command -v clip.exe >/dev/null 2>&1; then
  kubectl -n "$NS" get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d | clip.exe
  echo "Grafana admin password copied to the clipboard (user: admin), not printed"
fi
trap 'kill 0' EXIT
kubectl -n "$NS" port-forward --address 127.0.0.1 svc/prometheus 9090:9090 &
kubectl -n "$NS" port-forward --address 127.0.0.1 svc/grafana 3000:3000 &
echo "open http://localhost:9090 and http://localhost:3000. Ctrl-C stops both."
wait
