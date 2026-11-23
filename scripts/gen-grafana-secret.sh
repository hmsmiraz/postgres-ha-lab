#!/usr/bin/env bash
# Generate the Grafana admin password once into the Secret grafana-admin. Never printed, never committed.
# An existing Secret is kept, so a rerun rotates nothing.
set -euo pipefail
NS="${NS:-pg-ha}"
umask 077

if kubectl -n "$NS" get secret grafana-admin >/dev/null 2>&1; then
  echo "secret grafana-admin already exists, keeping it"
  exit 0
fi

kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
type: Opaque
stringData:
  admin-password: "$(openssl rand -hex 16)"
YAML
echo "secret grafana-admin created"
