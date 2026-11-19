#!/usr/bin/env bash
# Generate database credentials once. Never committed, never printed.
set -euo pipefail
NS=pg-ha

if kubectl -n "$NS" get secret pg-credentials >/dev/null 2>&1; then
  echo "secret pg-credentials already exists, keeping it"
  exit 0
fi

gen() { openssl rand -base64 33 | tr -d '/+=' | cut -c1-32; }

kubectl -n "$NS" apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: pg-credentials
type: Opaque
stringData:
  superuser-password: "$(gen)"
  replication-password: "$(gen)"
  rewind-password: "$(gen)"
  restapi-password: "$(gen)"
  app-password: "$(gen)"
YAML
