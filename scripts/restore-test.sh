#!/usr/bin/env bash
# RS-3 (ADR-0006, on-demand single-pod option): restore the latest backup plus the archived WAL of the live stanza into ONE
# scratch Postgres pod in the fixed namespace pg-restore (emptyDir data, plain Postgres, archiving off), wait for the end of
# recovery, run the caller's data check and compare it with the expected value, and remove the pod unless RESTORE_TEST_KEEP=1.
# Inputs (environment): RESTORE_TEST_SQL (a query that returns one value), RESTORE_TEST_EXPECT (the expected value),
# RESTORE_TEST_KEEP (1 keeps the pod), RESTORE_TEST_TIMEOUT (seconds to wait, default 600).
# Creates the namespace and copies the Secrets objstore-credentials and objstore-ca (ca.crt only) from pg-ha only when they are
# missing; values are never printed. It never deletes a namespace and accepts only pg-restore. Prints row counts, not data.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=pg-ha
DST=pg-restore
POD=pg-restore-test
[ "${1:-$DST}" = "$DST" ] || { echo "restore-test: the only namespace allowed is $DST" >&2; exit 2; }
# shellcheck source=/dev/null
source versions.env
IMG="${IMAGE_NAME}:${IMAGE_TAG}"
SQL="${RESTORE_TEST_SQL:?restore-test: RESTORE_TEST_SQL is not set}"
EXPECT="${RESTORE_TEST_EXPECT:?restore-test: RESTORE_TEST_EXPECT is not set}"
KEEP="${RESTORE_TEST_KEEP:-0}"
WAIT="${RESTORE_TEST_TIMEOUT:-600}"

# shellcheck disable=SC2329
cleanup() {
  if [ "$KEEP" != 1 ]; then
    kubectl -n "$DST" delete pod "$POD" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

for s in objstore-credentials objstore-tls; do
  kubectl -n "$SRC" get secret "$s" >/dev/null 2>&1 || { echo "restore-test: secret $s is missing in $SRC" >&2; exit 1; }
done
if ! kubectl get ns "$DST" >/dev/null 2>&1; then
  kubectl apply -f k8s/restore/00-namespace.yaml >/dev/null
  echo "restore-test: namespace $DST created"
fi
if ! kubectl -n "$DST" get secret objstore-credentials >/dev/null 2>&1; then
  kubectl -n "$SRC" get secret objstore-credentials -o json \
    | jq --arg ns "$DST" '{apiVersion:"v1",kind:"Secret",metadata:{name:"objstore-credentials",namespace:$ns},type:.type,data:.data}' \
    | kubectl apply -f - >/dev/null
  echo "restore-test: secret objstore-credentials copied (values not printed)"
fi
if ! kubectl -n "$DST" get secret objstore-ca >/dev/null 2>&1; then
  kubectl -n "$SRC" get secret objstore-tls -o json \
    | jq --arg ns "$DST" '{apiVersion:"v1",kind:"Secret",metadata:{name:"objstore-ca",namespace:$ns},type:"Opaque",data:{"ca.crt":.data["ca.crt"]}}' \
    | kubectl apply -f - >/dev/null
  echo "restore-test: secret objstore-ca created from ca.crt only"
fi

kubectl -n "$DST" delete pod "$POD" --ignore-not-found --wait=true --timeout=120s >/dev/null
sed "s|__IMAGE__|${IMG}|g" k8s/restore/60-restore-test-pod.yaml | kubectl apply -f - >/dev/null
echo "restore-test: pod $POD started, waiting for the restore and the end of recovery"

state=waiting
deadline=$((SECONDS + WAIT))
while [ "$SECONDS" -lt "$deadline" ]; do
  st=$(kubectl -n "$DST" get pod "$POD" -o json 2>/dev/null || true)
  phase=$(jq -r '.status.phase // "unknown"' <<<"$st" 2>/dev/null || echo unknown)
  ready=$(jq -r '.status.containerStatuses[0].ready // false' <<<"$st" 2>/dev/null || echo false)
  if [ "$ready" = true ]; then state=ready; break; fi
  if [ "$phase" = Failed ]; then state=failed; break; fi
  sleep 3
done
if [ "$state" != ready ]; then
  echo "restore-test: the scratch instance did not become ready ($state)" >&2
  kubectl -n "$DST" logs "$POD" --tail=12 >&2 || true
  exit 1
fi
echo "restore-test: the scratch instance is ready, recovery has ended"
# A checkpoint makes the new timeline visible in pg_control for callers that read it.
kubectl -n "$DST" exec "$POD" -c postgres -- psql -h /run/postgresql -U postgres -d appdb -Atq -c "checkpoint" </dev/null >/dev/null

got=$(kubectl -n "$DST" exec "$POD" -c postgres -- psql -h /run/postgresql -U postgres -d appdb -v ON_ERROR_STOP=1 -Atq -c "$SQL" </dev/null) \
  || { echo "restore-test: the data query failed" >&2; exit 1; }
if [ "$got" != "$EXPECT" ]; then
  echo "restore-test: data check FAILED: rows ${got%%:*}, expected ${EXPECT%%:*}, checksum match: no" >&2
  exit 1
fi
echo "restore-test: data check passed: rows ${got%%:*}, checksum match: yes"
