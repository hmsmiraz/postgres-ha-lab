#!/usr/bin/env bash
# FO-1: a crashed primary pod is recovered automatically. Measures RTO.
# RTO = largest gap between consecutive acknowledged writes through pg-primary.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source tests/lib/probe.sh

TARGET_RTO_S=60
LOG=$(mktemp)
trap 'kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true; rm -f "$LOG"' EXIT

echo "date: $(date -u +%FT%TZ)"
wait_healthy 120 || fail "cluster is not healthy before the test"
old=$(current_leader)
echo "leader before: $old"

start_probe
before=$(kubectl -n "$NS" logs "$PROBE" | grep -c '^ok ' || true)
[ "$before" -ge 20 ] || fail "probe is not writing before the kill ($before acknowledged writes)"
pass "probe writing before the kill ($before acknowledged writes)"

kill_ms=$(now_ms)
echo "killing $old (force delete, grace period 0) at $kill_ms"
kubectl -n "$NS" delete pod "$old" --grace-period=0 --force >/dev/null 2>&1

deadline=$((SECONDS + 180))
until kubectl -n "$NS" logs "$PROBE" > "$LOG" && awk -v k="$kill_ms" '$1=="ok" && $2>k {f=1} END {exit !f}' "$LOG"; do
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

missing=$(acked_missing "$LOG")
[ "$missing" = 0 ] || fail "$missing acknowledged write(s) are missing after failover"
pass "no acknowledged write was lost (0 missing out of $oks)"

n=$(writable_primaries)
[ "$n" = 1 ] || fail "$n pods accept writes, expected exactly 1"
pass "exactly one pod accepts writes"
echo "ALL CHECKS PASSED"
