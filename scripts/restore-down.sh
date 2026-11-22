#!/usr/bin/env bash
# RS-1 (ADR-0006): delete the fixed scratch namespace pg-restore: its pods, their volumes, the copied Secrets, the Role and the
# Services. It deletes nothing else and refuses any other namespace name. A missing namespace is not an error.
set -euo pipefail
NS=pg-restore
[ "${1:-$NS}" = "$NS" ] || { echo "restore-down: the only namespace this script deletes is $NS" >&2; exit 2; }
if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  echo "restore-down: namespace $NS does not exist, nothing to delete"
  exit 0
fi
echo "restore-down: deleting namespace $NS, which holds:"
kubectl -n "$NS" get sts,pod,pvc,secret,cm,svc,role,rolebinding,sa -o name | sed 's/^/  /'
kubectl delete namespace "$NS" --wait=true --timeout=300s
echo "restore-down: namespace $NS deleted"
