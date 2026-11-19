#!/usr/bin/env bash
# FO-3: the primary's storage is lost (PVC deleted together with the pod).
# A replica must be promoted, and the old pod must come back with fresh storage
# and rejoin as a replica by re-cloning, with no manual step.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source tests/lib/probe.sh

TARGET_RTO_S=90
LOG=$(mktemp)
trap 'kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true; rm -f "$LOG"' EXIT

echo "date: $(date -u +%FT%TZ)"
wait_healthy 120 || fail "cluster is not healthy before the test"
old=$(current_leader)
pvc="data-${old}"
uid_before=$(kubectl -n "$NS" get pvc "$pvc" -o jsonpath='{.metadata.uid}')
tl_before=$(cluster_json | jq -r '.[] | select(.Role == "Leader") | .TL')
echo "leader before: $old, pvc $pvc, uid $uid_before, timeline $tl_before"

start_probe
before=$(kubectl -n "$NS" logs "$PROBE" | grep -c '^ok ' || true)
[ "$before" -ge 20 ] || fail "probe is not writing before the failure ($before acknowledged writes)"
pass "probe writing before the failure ($before acknowledged writes)"

kill_ms=$(now_ms)
echo "deleting pvc $pvc and force-deleting pod $old at $kill_ms"
kubectl -n "$NS" delete pvc "$pvc" --wait=false >/dev/null
kubectl -n "$NS" delete pod "$old" --grace-period=0 --force >/dev/null 2>&1

deadline=$((SECONDS + 240))
until kubectl -n "$NS" logs "$PROBE" > "$LOG" && awk -v k="$kill_ms" '$1=="ok" && $2>k+2000 {f=1} END {exit !f}' "$LOG"; do
  [ "$SECONDS" -lt "$deadline" ] || fail "writes did not resume within 240 s"
  sleep 1
done
pass "writes through pg-primary resumed without any manual change"

new=""
deadline=$((SECONDS + 120))
while [ "$SECONDS" -lt "$deadline" ]; do
  new=$(current_leader 2>/dev/null || true)
  if [ -n "$new" ] && [ "$new" != "$old" ]; then break; fi
  sleep 3
done
echo "leader after: $new"
[ -n "$new" ] && [ "$new" != "$old" ] || fail "no replica was promoted (leader is still '$new')"
pass "replica $new was promoted automatically"

wait_healthy 600 || { cluster_table || true; fail "cluster did not return to 1 leader + 2 streaming replicas"; }
cluster_table

uid_after=$(kubectl -n "$NS" get pvc "$pvc" -o jsonpath='{.metadata.uid}')
echo "pvc uid after: $uid_after"
[ "$uid_after" != "$uid_before" ] || fail "the PVC was not replaced (same uid)"
pass "storage was really replaced (new PVC uid)"

role=$(cluster_json | jq -r --arg m "$old" '.[] | select(.Member == $m) | .Role')
echo "old primary $old now has role: $role"
case "$role" in
  Replica|"Sync Standby") pass "old pod $old re-cloned and rejoined as a replica" ;;
  *) fail "old pod $old has unexpected role '$role'" ;;
esac
echo "--- how $old got its data (from its log) ---"
kubectl -n "$NS" logs "$old" -c postgres 2>/dev/null | grep -iE "bootstrap|basebackup|clone|empty|replica" | head -8 || true

sleep 10
kubectl -n "$NS" logs "$PROBE" > "$LOG"
cp "$LOG" docs/evidence/FO-3-probe.log
read -r oks errs max_gap _ < <(analyze_probe "$LOG" "$kill_ms")
echo "acknowledged writes: $oks, failed attempts: $errs"
echo "largest gap between acknowledged writes (RTO): ${max_gap} ms"
[ "$max_gap" -le $((TARGET_RTO_S * 1000)) ] || fail "RTO ${max_gap} ms is above the ${TARGET_RTO_S} s target"
pass "RTO ${max_gap} ms is within the ${TARGET_RTO_S} s target"

missing=$(acked_missing_verbose "$LOG")
[ "$missing" = 0 ] || fail "acknowledged writes missing after failover: $missing"
pass "no acknowledged write was lost (0 missing out of $oks)"

tl_after=$(cluster_json | jq -r '.[] | select(.Role == "Leader") | .TL')
echo "timeline before: $tl_before, after: $tl_after"
[ "$tl_after" -gt "$tl_before" ] || fail "timeline did not advance"
pass "timeline advanced ($tl_before -> $tl_after)"

n=$(writable_primaries)
[ "$n" = 1 ] || fail "$n pods accept writes, expected exactly 1"
pass "exactly one pod accepts writes"
echo "ALL CHECKS PASSED"
