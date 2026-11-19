#!/usr/bin/env bash
# FO-4: the primary is alive but cut off from the Kubernetes API (network partition).
# The cut is an iptables DROP on the node, in both directions, so it also kills
# connections that are already open. It must demote itself, a replica must be promoted,
# and two writable primaries must never be seen at the same time.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source tests/lib/probe.sh

TARGET_RTO_S=90
LOG=$(mktemp)
SAMPLES=$(mktemp)
sampler_pid=""
EXCLUDE=""
cut_done=""
node=""; old_ip=""; api_ip=""

# While a pod is cut off from the API, patronictl inside it cannot answer, so skip it.
cluster_json() {
  local pod
  for pod in pg-ha-0 pg-ha-1 pg-ha-2; do
    [ "$pod" = "$EXCLUDE" ] && continue
    timeout 20 kubectl -n "$NS" exec "$pod" -c postgres -- \
      patronictl -c /etc/patroni/patroni.yml list -f json 2>/dev/null && return 0
  done
  return 1
}

cut() {
  docker exec "$node" iptables -w -I FORWARD 1 -s "$old_ip" -d "$api_ip" -j DROP
  docker exec "$node" iptables -w -I FORWARD 1 -s "$api_ip" -d "$old_ip" -j DROP
  cut_done=yes
}
heal() {
  docker exec "$node" iptables -w -D FORWARD -s "$old_ip" -d "$api_ip" -j DROP 2>/dev/null || true
  docker exec "$node" iptables -w -D FORWARD -s "$api_ip" -d "$old_ip" -j DROP 2>/dev/null || true
  cut_done=""
}
renew_time() { kubectl -n "$NS" get configmap pg-ha-leader -o jsonpath='{.metadata.annotations.renewTime}'; }

cleanup() {
  if [ -n "$sampler_pid" ]; then kill "$sampler_pid" 2>/dev/null || true; fi
  if [ -n "$cut_done" ]; then echo "cleanup: removing the partition"; heal; fi
  kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -f "$LOG" "$SAMPLES"
}
trap cleanup EXIT

# One line per pod per second: "<ms> <round> <pod> <f|t|x>" (f = accepts writes, t = read-only, x = no answer).
sampler() {
  local round=0 pod
  while true; do
    round=$((round + 1))
    for pod in pg-ha-0 pg-ha-1 pg-ha-2; do
      (
        r=$(timeout 3 kubectl -n "$NS" exec "$pod" -c postgres -- \
          psql -U postgres -Atqc "select pg_is_in_recovery()" 2>/dev/null || true)
        echo "$(now_ms) $round $pod ${r:-x}" >> "$SAMPLES"
      ) &
    done
    wait
    sleep 1
  done
}

echo "date: $(date -u +%FT%TZ)"
wait_healthy 120 || fail "cluster is not healthy before the test"
old=$(current_leader)
tl_before=$(cluster_json | jq -r '.[] | select(.Role == "Leader") | .TL')
node=$(kubectl -n "$NS" get pod "$old" -o jsonpath='{.spec.nodeName}')
old_ip=$(kubectl -n "$NS" get pod "$old" -o jsonpath='{.status.podIP}')
api_ip=$(kubectl get endpointslices -l kubernetes.io/service-name=kubernetes \
  -o jsonpath='{.items[0].endpoints[0].addresses[0]}')
echo "leader before: $old (timeline $tl_before) on node $node, pod IP $old_ip, API server $api_ip"

start_probe
before=$(kubectl -n "$NS" logs "$PROBE" | grep -c '^ok ' || true)
[ "$before" -ge 20 ] || fail "probe is not writing before the partition ($before acknowledged writes)"
pass "probe writing before the partition ($before acknowledged writes)"

sampler &
sampler_pid=$!
sleep 5

partition_ms=$(now_ms)
echo "cutting $old off from the Kubernetes API (iptables DROP on $node) at $partition_ms"
cut
sleep 2
rt1=$(renew_time)
sleep 14
rt2=$(renew_time)
echo "leader lock renewTime at +2 s: $rt1"
echo "leader lock renewTime at +16 s: $rt2"
[ "$rt1" = "$rt2" ] || fail "the partition did not work: $old is still renewing the leader lock"
pass "method check: $old can no longer renew the leader lock (renewTime stopped)"
EXCLUDE="$old"

new=""
deadline=$((SECONDS + 180))
while [ "$SECONDS" -lt "$deadline" ]; do
  new=$(current_leader 2>/dev/null || true)
  if [ -n "$new" ] && [ "$new" != "$old" ]; then break; fi
  sleep 3
done
echo "leader after: $new"
[ -n "$new" ] && [ "$new" != "$old" ] || fail "no replica was promoted while $old was partitioned"
pass "replica $new was promoted automatically"

fenced=""
deadline=$((SECONDS + 90))
while [ "$SECONDS" -lt "$deadline" ]; do
  r=$(timeout 20 kubectl -n "$NS" exec "$old" -c postgres -- psql -U postgres -Atqc "select pg_is_in_recovery()" 2>/dev/null || true)
  if [ "$r" = "t" ]; then fenced=yes; break; fi
  sleep 3
done
[ "$fenced" = yes ] || fail "the partitioned old primary $old is still accepting writes"
pass "the partitioned old primary $old demoted itself (now read-only)"

if timeout 25 kubectl -n "$NS" exec "$old" -c postgres -- \
     psql -U postgres -d appdb -Atq -v ON_ERROR_STOP=1 \
     -c "set statement_timeout = 3000" -c "insert into fo_probe(ts_ms) values (-1)" >/dev/null 2>&1; then
  fail "a direct write to the old primary $old was accepted (split-brain)"
fi
pass "a direct write to the old primary $old is rejected"

echo "healing the partition"
heal
EXCLUDE=""
wait_healthy 600 || { cluster_table || true; fail "cluster did not return to 1 leader + 2 streaming replicas"; }
cluster_table
role=$(cluster_json | jq -r --arg m "$old" '.[] | select(.Member == $m) | .Role')
echo "old primary $old now has role: $role"
case "$role" in
  Replica|"Sync Standby") pass "old primary $old rejoined as a replica after the partition healed" ;;
  *) fail "old primary $old has unexpected role '$role'" ;;
esac
echo "--- rewind-related lines from $old (informational) ---"
kubectl -n "$NS" logs "$old" -c postgres 2>/dev/null | grep -iE "rewind|diverg|demot|timeline" | tail -8 || true

sleep 10
kill "$sampler_pid" 2>/dev/null || true
sampler_pid=""
cp "$SAMPLES" docs/evidence/FO-4-samples.log
kubectl -n "$NS" logs "$PROBE" > "$LOG"
cp "$LOG" docs/evidence/FO-4-probe.log

rounds=$(awk '{print $2}' "$SAMPLES" | sort -u | wc -l)
max_writable=$(awk '$4=="f" {c[$2]++} END {m=0; for (r in c) if (c[r]>m) m=c[r]; print m}' "$SAMPLES")
echo "NOTE: pods are sampled about 0.3 s apart within a round, so this shows no sustained overlap."
echo "sampling rounds: $rounds, most writable pods seen in one round: $max_writable"
[ "$max_writable" -le 1 ] || fail "two writable primaries were seen in the same sampling round"
pass "never more than one writable primary in $rounds sampling rounds"

demote_ms=$(awk -v p="$partition_ms" -v o="$old" '$3==o && $4=="t" && $1>p {print $1; exit}' "$SAMPLES")
promote_ms=$(awk -v p="$partition_ms" -v o="$old" '$3!=o && $4=="f" && $1>p {print $1; exit}' "$SAMPLES")
if [ -n "$demote_ms" ]; then echo "old primary read-only $((demote_ms - partition_ms)) ms after the partition started"; fi
if [ -n "$promote_ms" ]; then echo "new primary writable $((promote_ms - partition_ms)) ms after the partition started"; fi

read -r oks errs max_gap _ < <(analyze_probe "$LOG" "$partition_ms")
echo "acknowledged writes: $oks, failed attempts: $errs"
echo "largest gap between acknowledged writes (RTO): ${max_gap} ms"
[ "$max_gap" -le $((TARGET_RTO_S * 1000)) ] || fail "RTO ${max_gap} ms is above the ${TARGET_RTO_S} s target"
pass "RTO ${max_gap} ms is within the ${TARGET_RTO_S} s target"

missing=$(acked_missing_verbose "$LOG")
[ "$missing" = 0 ] || fail "acknowledged writes missing after the partition: $missing"
pass "no acknowledged write was lost (0 missing out of $oks)"

tl_after=$(cluster_json | jq -r '.[] | select(.Role == "Leader") | .TL')
echo "timeline before: $tl_before, after: $tl_after"
[ "$tl_after" -gt "$tl_before" ] || fail "timeline did not advance"
pass "timeline advanced ($tl_before -> $tl_after)"

n=$(writable_primaries)
[ "$n" = 1 ] || fail "$n pods accept writes, expected exactly 1"
pass "exactly one pod accepts writes at the end"
echo "ALL CHECKS PASSED"
