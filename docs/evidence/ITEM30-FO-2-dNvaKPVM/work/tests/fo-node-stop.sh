#!/usr/bin/env bash
# FO-2: the node running the primary is powered off. A replica must be promoted
# automatically, and the old primary must rejoin as a replica when its node returns.
# RTO = largest gap between consecutive acknowledged writes through pg-primary.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source tests/lib/probe.sh

TARGET_RTO_S=90
LOG=$(mktemp)
node=""

cleanup() {
  kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if [ -n "$node" ] && [ "$(docker inspect -f '{{.State.Running}}' "$node" 2>/dev/null || echo false)" != "true" ]; then
    echo "cleanup: starting $node again"
    docker start "$node" >/dev/null || true
  fi
  rm -f "$LOG"
}
trap cleanup EXIT

echo "date: $(date -u +%FT%TZ)"
wait_healthy 120 || fail "cluster is not healthy before the test"
old=$(current_leader)
node=$(kubectl -n "$NS" get pod "$old" -o jsonpath='{.spec.nodeName}')
echo "leader before: $old on node $node"
tl_before=$(cluster_json | jq -r '.[] | select(.Role == "Leader") | .TL')

start_probe
before=$(kubectl -n "$NS" logs "$PROBE" | grep -c '^ok ' || true)
[ "$before" -ge 20 ] || fail "probe is not writing before the failure ($before acknowledged writes)"
pass "probe writing before the failure ($before acknowledged writes)"

kill_ms=$(now_ms)
echo "powering off node $node (docker kill) at $kill_ms"
docker kill "$node" >/dev/null

deadline=$((SECONDS + 240))
until kubectl -n "$NS" logs "$PROBE" > "$LOG" && awk -v k="$kill_ms" '$1=="ok" && $2>k {f=1} END {exit !f}' "$LOG"; do
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
pass "replica $new was promoted automatically (the old primary's node is down)"

sleep 10
kubectl -n "$NS" logs "$PROBE" > "$LOG"
read -r oks errs max_gap ttr < <(analyze_probe "$LOG" "$kill_ms")
echo "acknowledged writes: $oks, failed attempts: $errs"
echo "time from node power-off to first successful write: ${ttr} ms"
echo "largest gap between acknowledged writes (RTO): ${max_gap} ms"
[ "$max_gap" -le $((TARGET_RTO_S * 1000)) ] || fail "RTO ${max_gap} ms is above the ${TARGET_RTO_S} s target"
pass "RTO ${max_gap} ms is within the ${TARGET_RTO_S} s target"

cp "$LOG" docs/evidence/FO-2-probe.log
missing=$(acked_missing_verbose "$LOG")
[ "$missing" = 0 ] || fail "$missing acknowledged write(s) are missing after failover"
pass "no acknowledged write was lost (0 missing out of $oks)"

echo "starting node $node again"
docker start "$node" >/dev/null
wait_healthy 600 || { cluster_table || true; fail "cluster did not return to 1 leader + 2 streaming replicas"; }
cluster_table
role=$(cluster_json | jq -r --arg m "$old" '.[] | select(.Member == $m) | .Role')
echo "old primary $old now has role: $role"
case "$role" in
  Replica|"Sync Standby") pass "old primary $old rejoined automatically as a replica" ;;
  *) fail "old primary $old has unexpected role '$role'" ;;
esac

tl_after=$(cluster_json | jq -r '.[] | select(.Role == "Leader") | .TL')
echo "timeline before: $tl_before, after: $tl_after"
[ "$tl_after" -gt "$tl_before" ] || fail "timeline did not advance"
pass "timeline advanced ($tl_before -> $tl_after)"

n=$(writable_primaries)
[ "$n" = 1 ] || fail "$n pods accept writes, expected exactly 1"
pass "exactly one pod accepts writes after the node returned"
echo "ALL CHECKS PASSED"
