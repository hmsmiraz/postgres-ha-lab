#!/usr/bin/env bash
# FO-5: after real divergence, the old primary rejoins automatically as a replica.
# Divergence: rows committed only on the old primary (replication cut, synchronous_commit=local),
# then its node is powered off so a replica is promoted without them.
# The cut is a separate nftables table at priority -150, so Calico's own chains cannot reorder it.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source tests/lib/probe.sh

node=""; old_ip=""
peers=(); peer_pods=()
cut_done=""

psql_pod() { timeout 20 kubectl -n "$NS" exec "$1" -c postgres -- psql -U postgres -d appdb -Atq -v ON_ERROR_STOP=1 -c "$2"; }

cut() {
  local ip
  docker exec "$node" nft add table ip pgha_fence || return 1
  docker exec "$node" nft "add chain ip pgha_fence isolate { type filter hook forward priority -150 ; policy accept ; }" || return 1
  for ip in "${peers[@]}"; do
    docker exec "$node" nft add rule ip pgha_fence isolate ip saddr "$old_ip" ip daddr "$ip" counter drop || return 1
    docker exec "$node" nft add rule ip pgha_fence isolate ip saddr "$ip" ip daddr "$old_ip" counter drop || return 1
  done
  cut_done=yes
}
heal() {
  docker exec "$node" nft delete table ip pgha_fence 2>/dev/null || true
  cut_done=""
}
cleanup() {
  if [ -n "$node" ]; then
    if [ "$(docker inspect -f '{{.State.Running}}' "$node" 2>/dev/null || echo false)" != "true" ]; then
      echo "cleanup: starting $node again"
      docker start "$node" >/dev/null || true
    elif [ -n "$cut_done" ]; then
      echo "cleanup: removing the replication cut"
      heal
    fi
  fi
}
trap cleanup EXIT

echo "date: $(date -u +%FT%TZ)"
wait_healthy 120 || fail "cluster is not healthy before the test"
old=$(current_leader)
node=$(kubectl -n "$NS" get pod "$old" -o jsonpath='{.spec.nodeName}')
old_ip=$(kubectl -n "$NS" get pod "$old" -o jsonpath='{.status.podIP}')
tl_before=$(cluster_json | jq -r '.[] | select(.Role == "Leader") | .TL')
pods_json=$(kubectl -n "$NS" get pods -l application=pg-ha,cluster-name=pg-ha -o json)
mapfile -t peers < <(jq -r --arg o "$old" '.items[] | select(.metadata.name != $o) | .status.podIP' <<<"$pods_json")
mapfile -t peer_pods < <(jq -r --arg o "$old" '.items[] | select(.metadata.name != $o) | .metadata.name' <<<"$pods_json")
echo "leader before: $old (timeline $tl_before) on $node, replicas: ${peer_pods[*]}"

psql_pod "$old" "drop table if exists rejoin_probe" >/dev/null 2>&1
psql_pod "$old" "create table rejoin_probe(id bigserial primary key, note text not null)" >/dev/null
psql_pod "$old" "insert into rejoin_probe(note) values ('baseline')" >/dev/null
for p in "${peer_pods[@]}"; do
  ok=""
  for _ in $(seq 1 30); do
    c=$(psql_pod "$p" "select count(*) from rejoin_probe where note = 'baseline'" 2>/dev/null || true)
    if [ "$c" = 1 ]; then ok=yes; break; fi
    sleep 1
  done
  [ "$ok" = yes ] || fail "the baseline row did not reach $p"
done
pass "baseline row replicated to both replicas"

echo "cutting replication between $old and its replicas (nftables, API access stays up)"
cut || fail "the nft rules could not be installed, so there is no cut to test"
docker exec "$node" nft list table ip pgha_fence
timeout 25 kubectl -n "$NS" exec -i "$old" -c postgres -- \
  psql -U postgres -d appdb -Atq -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
set synchronous_commit = local;
insert into rejoin_probe(note) select 'divergent-' || g from generate_series(1,5) g;
SQL
n_old=$(psql_pod "$old" "select count(*) from rejoin_probe where note like 'divergent-%'")
[ "$n_old" = 5 ] || fail "expected 5 divergent rows on the old primary, found $n_old"
for wait_s in 5 10; do
  sleep "$wait_s"
  for p in "${peer_pods[@]}"; do
    c=$(psql_pod "$p" "select count(*) from rejoin_probe where note like 'divergent-%'")
    [ "$c" = 0 ] || fail "the cut did not hold: $p has $c divergent row(s)"
  done
done
pass "5 rows exist only on the old primary $old (replicas still have none after 15 s)"

echo "powering off node $node (docker kill)"
docker kill "$node" >/dev/null
cut_done=""
new=""
deadline=$((SECONDS + 180))
while [ "$SECONDS" -lt "$deadline" ]; do
  new=$(current_leader 2>/dev/null || true)
  if [ -n "$new" ] && [ "$new" != "$old" ]; then break; fi
  sleep 3
done
echo "leader after: $new"
[ -n "$new" ] && [ "$new" != "$old" ] || fail "no replica was promoted"
pass "replica $new was promoted (it never had the divergent rows)"

echo "starting node $node again"
docker start "$node" >/dev/null
wait_healthy 600 || { cluster_table || true; fail "cluster did not return to 1 leader + 2 streaming replicas"; }
cluster_table
role=$(cluster_json | jq -r --arg m "$old" '.[] | select(.Member == $m) | .Role')
echo "old primary $old now has role: $role"
case "$role" in
  Replica|"Sync Standby") pass "old primary $old rejoined as a replica with no manual step" ;;
  *) fail "old primary $old has unexpected role '$role'" ;;
esac

for p in pg-ha-0 pg-ha-1 pg-ha-2; do
  d=$(psql_pod "$p" "select count(*) from rejoin_probe where note like 'divergent-%'")
  b=$(psql_pod "$p" "select count(*) from rejoin_probe where note = 'baseline'")
  echo "$p: divergent rows=$d, baseline rows=$b"
  [ "$d" = 0 ] || fail "$p still has divergent rows"
  [ "$b" = 1 ] || fail "$p lost the baseline row"
done
pass "divergent rows are gone from every node, the baseline row is on every node"

logs=$( { kubectl -n "$NS" logs "$old" -c postgres 2>/dev/null; kubectl -n "$NS" logs "$old" -c postgres --previous 2>/dev/null; } || true)
echo "--- rejoin-related log lines from $old ---"
grep -iE "pg_rewind|rewind|reinitializ|bootstrap from|basebackup" <<<"$logs" | tail -12 || true
if grep -qi "running pg_rewind" <<<"$logs"; then
  method="pg_rewind"
elif grep -qiE "reinitializ|bootstrap from|basebackup" <<<"$logs"; then
  method="re-clone"
else
  method="unknown"
fi
echo "rejoin method: $method"
[ "$method" != unknown ] || fail "the logs do not show how $old rejoined"
pass "rejoin method identified from the logs: $method"

tl_after=$(cluster_json | jq -r '.[] | select(.Role == "Leader") | .TL')
echo "timeline before: $tl_before, after: $tl_after"
[ "$tl_after" -gt "$tl_before" ] || fail "timeline did not advance"
pass "timeline advanced ($tl_before -> $tl_after)"

n=$(writable_primaries)
[ "$n" = 1 ] || fail "$n pods accept writes, expected exactly 1"
pass "exactly one pod accepts writes"
echo "ALL CHECKS PASSED"
