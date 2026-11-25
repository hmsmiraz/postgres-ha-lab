#!/usr/bin/env bash
# FO-1: a crashed primary pod is recovered automatically. Measures RTO.
# RTO = largest gap between consecutive acknowledged writes through pg-primary.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source tests/lib/probe.sh

TARGET_RTO_S=60
LOG=$(mktemp)
cordoned=""
cleanup() {
  if [ -n "$cordoned" ]; then kubectl uncordon "$cordoned"; fi
  kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -f "$LOG"
}
trap cleanup EXIT

echo "date: $(date -u +%FT%TZ)"
wait_healthy 120 || fail "cluster is not healthy before the test"
old=$(current_leader)
old_uid=$(kubectl -n "$NS" get pod "$old" -o jsonpath='{.metadata.uid}')
echo "leader before: $old"

start_probe
deadline=$((SECONDS + 60))
while :; do
  before=$(kubectl -n "$NS" logs "$PROBE" | grep -c '^ok ' || true)
  [ "$before" -ge 20 ] && break
  [ "$SECONDS" -lt "$deadline" ] || fail "probe could not acknowledge 20 writes before the drill"
  sleep 1
done
pass "probe writing before the kill ($before acknowledged writes)"

if [ "${FO_HOLD_REPLACEMENT:-0}" = 1 ]; then
  node=$(kubectl -n "$NS" get pod "$old" -o jsonpath='{.spec.nodeName}')
  [ "$(kubectl get node "$node" -o jsonpath='{.spec.unschedulable}')" != true ] || fail "worker already cordoned"
  kubectl cordon "$node"
  cordoned=$node
fi
kill_ms=$(now_ms)
echo "killing $old (force delete, grace period 0) at $kill_ms"
kubectl -n "$NS" delete pod "$old" --grace-period=0 --force >/dev/null 2>&1

if [ -n "$cordoned" ]; then
  deadline=$((SECONDS + 120))
  while :; do
    new=$(current_leader || true)
    if [ -n "$new" ] && [ "$new" != "$old" ]; then break; fi
    [ "$SECONDS" -lt "$deadline" ] || fail "no replica promoted while replacement was held"
    sleep 2
  done
  pass "$new promoted while replacement of $old was held"
  kubectl uncordon "$cordoned"
  cordoned=""
fi
# An in-flight write or a stale Patroni record can survive the delete call.
deadline=$((SECONDS + 300))
while :; do
  uid=$(kubectl -n "$NS" get pod "$old" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
  if [ -n "$uid" ] && [ "$uid" != "$old_uid" ]; then break; fi
  [ "$SECONDS" -lt "$deadline" ] || fail "the replacement pod was never created"
  sleep 1
done
kubectl -n "$NS" wait --for=condition=Ready "pod/$old" --timeout=300s || fail "replacement pod never became ready"
ready_ms=$(now_ms)
deadline=$((SECONDS + 180))
until kubectl -n "$NS" logs "$PROBE" > "$LOG" && awk -v k="$ready_ms" '$1=="ok" && $2>k {f=1} END {exit !f}' "$LOG"; do
  [ "$SECONDS" -lt "$deadline" ] || fail "writes did not resume within 180 s"
  sleep 1
done
pass "writes through pg-primary resumed without any manual change"

wait_healthy 300 || fail "cluster did not return to 1 leader + 2 streaming replicas"
new=$(current_leader)
echo "leader after: $new"
if [ "$new" = "$old" ]; then
  echo "NOTE: $old restarted in place and kept its leader lock (no promotion)"
else
  echo "NOTE: replica $new was promoted"
fi
cluster_table
pass "cluster is back to 1 leader + 2 streaming replicas"

sleep 10
kubectl -n "$NS" logs "$PROBE" > "$LOG"

read -r oks errs max_gap ttr < <(analyze_probe "$LOG" "$kill_ms")
echo "acknowledged writes: $oks, failed attempts: $errs"
echo "time from kill to first successful write: ${ttr} ms"
echo "largest gap between acknowledged writes (RTO): ${max_gap} ms"
[ "$max_gap" -le $((TARGET_RTO_S * 1000)) ] || fail "RTO ${max_gap} ms is above the ${TARGET_RTO_S} s target"
pass "RTO ${max_gap} ms is within the ${TARGET_RTO_S} s target"

missing=$(acked_missing_verbose "$LOG")
[ "$missing" = 0 ] || fail "$missing acknowledged write(s) are missing after failover"
pass "no acknowledged write was lost (0 missing out of $oks)"

n=$(writable_primaries)
[ "$n" = 1 ] || fail "$n pods accept writes, expected exactly 1"
pass "exactly one pod accepts writes"
echo "ALL CHECKS PASSED"
