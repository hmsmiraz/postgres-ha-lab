#!/usr/bin/env bash
# RS-1 (ADR-0006): full cluster restore into the fixed scratch namespace pg-restore, by one script.
# Creates the namespace, copies the Secrets it needs from pg-ha without printing them (pg-credentials, objstore-credentials,
# and ca.crt of objstore-tls as objstore-ca), applies the manifests of k8s/restore and waits for the restored 3-pod cluster.
# Stops if pg-restore already exists (run scripts/restore-down.sh first). The only namespace it accepts is pg-restore.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source versions.env

SRC=pg-ha
DST=pg-restore
IMG="${IMAGE_NAME}:${IMAGE_TAG}"
[ "${1:-$DST}" = "$DST" ] || { echo "restore-full: the only namespace allowed is $DST" >&2; exit 2; }
if kubectl get ns "$DST" >/dev/null 2>&1; then
  echo "restore-full: namespace $DST already exists; run scripts/restore-down.sh first" >&2
  exit 1
fi
for s in pg-credentials objstore-credentials objstore-tls; do
  kubectl -n "$SRC" get secret "$s" >/dev/null 2>&1 || { echo "restore-full: secret $s is missing in $SRC" >&2; exit 1; }
done

kubectl apply -f k8s/restore/00-namespace.yaml >/dev/null
echo "restore-full: namespace $DST created"
for s in pg-credentials objstore-credentials; do
  kubectl -n "$SRC" get secret "$s" -o json \
    | jq --arg ns "$DST" '{apiVersion:"v1",kind:"Secret",metadata:{name:.metadata.name,namespace:$ns},type:.type,data:.data}' \
    | kubectl apply -f - >/dev/null
  echo "restore-full: secret $s copied (values not printed)"
done
kubectl -n "$SRC" get secret objstore-tls -o json \
  | jq --arg ns "$DST" '{apiVersion:"v1",kind:"Secret",metadata:{name:"objstore-ca",namespace:$ns},type:"Opaque",data:{"ca.crt":.data["ca.crt"]}}' \
  | kubectl apply -f - >/dev/null
echo "restore-full: secret objstore-ca created from ca.crt only"

kubectl apply -f k8s/restore/10-rbac.yaml -f k8s/restore/20-config.yaml -f k8s/restore/30-services.yaml >/dev/null
# Optional point-in-time target (RS-2): RESTORE_TARGET, RESTORE_TYPE (default time), RESTORE_TARGET_ACTION (default promote).
# pgBackRest reads them from the ConfigMap pgbackrest-env in pg-restore; the pods read it when they start, after this patch.
RESTORE_TYPE="${RESTORE_TYPE:-time}"
RESTORE_TARGET_ACTION="${RESTORE_TARGET_ACTION:-promote}"
if [ -n "${RESTORE_TARGET:-}" ]; then
  kubectl -n "$DST" patch configmap pgbackrest-env --type merge \
    -p "$(jq -n --arg t "$RESTORE_TYPE" --arg g "$RESTORE_TARGET" --arg a "$RESTORE_TARGET_ACTION" '{data:{PGBACKREST_TYPE:$t,PGBACKREST_TARGET:$g,PGBACKREST_TARGET_ACTION:$a}}')" >/dev/null
  echo "restore-full: point-in-time target set: type $RESTORE_TYPE, target $RESTORE_TARGET, action $RESTORE_TARGET_ACTION"
fi
sed "s|__IMAGE__|${IMG}|g" k8s/restore/50-statefulset.yaml | kubectl apply -f - >/dev/null
echo "restore-full: manifests applied, waiting for the restored cluster"
kubectl -n "$DST" rollout status sts/pg-restore --timeout=900s
echo "restore-full: done"
