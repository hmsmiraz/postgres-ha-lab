#!/usr/bin/env bash
# ADR-0001, degraded case: no synchronous standby is reachable, then the primary is lost.
# Contract (Patroni synchronous mode, non-strict):
#  1. commits stall until Patroni switches to asynchronous (about wal_sender_timeout), then resume;
#  2. with no sync standby and no primary, no replica promotes itself (data protection);
#  3. when the old primary's node returns, every acknowledged write is still there;
#  4. synchronous mode comes back on its own.
set -Eeuo pipefail
trap 'echo "FAIL: command failed at line $LINENO: $BASH_COMMAND"' ERR
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source tests/lib/probe.sh

MAX_DEGRADE_S=180
HOLD_S=90
node=""; cut_done=""; writer_pid=""
peers=(); peer_pods=()
WDIR=$(mktemp -d)

psql_pod() { timeout 30 kubectl -n "$NS" exec "$1" -c postgres -- psql -U postgres -d appdb -Atq -v ON_ERROR_STOP=1 -c "$2"; }
acks() { grep -c '^ack' "$WDIR/writer.log" 2>/dev/null || true; }
in_recovery() { timeout 15 kubectl -n "$NS" exec "$1" -c postgres -- psql -U postgres -Atqc "select pg_is_in_recovery()" 2>/dev/null || true; }
writable_pod() {
  local p
  for p in pg-ha-0 pg-ha-1 pg-ha-2; do
    if [ "$(in_recovery "$p")" = "f" ]; then echo "$p"; return 0; fi
  done
  return 1
}

cut() {
  local ip
  docker exec "$node" nft add table ip pgha_fence || return 1
  docker exec "$node" nft "add chain ip pgha_fence isolate { type filter hook forward priority -150 ; policy accept ; }" || return 1
  for ip in "${peers[@]}"; do
    docker exec "$node" nft add rule ip pgha_fence isolate ip saddr "$leader_ip" ip daddr "$ip" counter drop || return 1
    docker exec "$node" nft add rule ip pgha_fence isolate ip saddr "$ip" ip daddr "$leader_ip" counter drop || return 1
  done
  cut_done=yes
}

cleanup() {
  if [ -n "$writer_pid" ]; then kill "$writer_pid" 2>/dev/null || true; fi
  if [ -n "$node" ]; then
    if [ "$(docker inspect -f '{{.State.Running}}' "$node" 2>/dev/null || echo false)" != "true" ]; then
      echo "cleanup: starting $node again"
      docker start "$node" >/dev/null || true
    elif [ -n "$cut_done" ]; then
      echo "cleanup: removing the replication cut"
      docker exec "$node" nft delete table ip pgha_fence 2>/dev/null || true
    fi
  fi
  rm -rf "$WDIR"
}
trap cleanup EXIT

echo "date: $(date -u +%FT%TZ)"
wait_healthy 120 || fail "cluster is not healthy before the test"
leader=$(current_leader)
node=$(kubectl -n "$NS" get pod "$leader" -o jsonpath='{.spec.nodeName}')
leader_ip=$(kubectl -n "$NS" get pod "$leader" -o jsonpath='{.status.podIP}')
pods_json=$(kubectl -n "$NS" get pods -l application=pg-ha,cluster-name=pg-ha -o json)
mapfile -t peers < <(jq -r --arg o "$leader" '.items[] | select(.metadata.name != $o) | .status.podIP' <<<"$pods_json")
mapfile -t peer_pods < <(jq -r --arg o "$leader" '.items[] | select(.metadata.name != $o) | .metadata.name' <<<"$pods_json")
sync_before=$(psql_pod "$leader" "show synchronous_standby_names")
echo "leader: $leader on $node; replicas: ${peer_pods[*]}; synchronous_standby_names before: $sync_before"
[ -n "$sync_before" ] || fail "synchronous mode is not active before the test"

psql_pod "$leader" "drop table if exists degraded_probe" >/dev/null 2>&1
psql_pod "$leader" "create table degraded_probe(n int primary key)" >/dev/null

# The writer runs inside the primary's pod: synchronous_commit on (default), no statement timeout.
# A blocked commit therefore shows up as a gap between two "ack" lines.
# shellcheck disable=SC2016
timeout 1500 kubectl -n "$NS" exec "$leader" -c postgres -- bash -c '
  i=0
  while true; do
    i=$((i + 1))
    if psql -U postgres -d appdb -Atq -v ON_ERROR_STOP=1 -c "insert into degraded_probe(n) values ($i)" >/dev/null 2>&1; then
      echo "ack $i $(date +%s%3N)"
    else
      echo "err $i $(date +%s%3N)"
    fi
    sleep 0.5
  done' >"$WDIR/writer.log" 2>/dev/null &
writer_pid=$!
sleep 6
[ "$(acks)" -ge 5 ] || fail "the writer is not acknowledging writes before the cut ($(acks))"
pass "writer acknowledging writes before the cut ($(acks) acks)"

cut || fail "the nft rules could not be installed, so there is no cut to test"
cut_ms=$(now_ms)
echo "cut: $leader is cut off from ${peer_pods[*]} (API access stays up) at $(date +%T)"

degraded_ms=""
t0=$SECONDS
while [ $((SECONDS - t0)) -lt "$MAX_DEGRADE_S" ]; do
  sleep 5
  names=""; ok=""
  if names=$(psql_pod "$leader" "show synchronous_standby_names" 2>/dev/null); then ok=yes; fi
  echo "t+$((SECONDS - t0))s synchronous_standby_names='${names}' acks=$(acks)"
  if [ -n "$ok" ] && [ -z "$names" ]; then degraded_ms=$(now_ms); break; fi
done
[ -n "$degraded_ms" ] || fail "Patroni did not fall back to asynchronous within ${MAX_DEGRADE_S} s; commits stay blocked"
echo "MEASURED: Patroni switched to asynchronous $(((degraded_ms - cut_ms) / 1000)) s after the cut"
pass "Patroni fell back to asynchronous replication on its own"

a0=$(acks)
sleep 15
a1=$(acks)
echo "acknowledged writes in the 15 s after the switch: $((a1 - a0))"
[ $((a1 - a0)) -ge 5 ] || fail "writes did not resume after the switch to asynchronous"
pass "writes resumed after the fall back"
max_gap=$(awk '$1=="ack" { if (prev) { g=$3-prev; if (g>m) m=g } prev=$3 } END { print m+0 }' "$WDIR/writer.log")
echo "MEASURED: longest gap between acknowledged writes (commit stall): ${max_gap} ms"

leader_n=$(psql_pod "$leader" "select count(*) from degraded_probe")
for p in "${peer_pods[@]}"; do
  c=$(psql_pod "$p" "select count(*) from degraded_probe")
  echo "rows on $p: $c, rows on the primary $leader: $leader_n"
  [ "$c" -lt "$leader_n" ] || fail "replica $p has all the rows; the cut did not isolate it"
done
pass "the replicas are behind: writes acknowledged in the degraded state exist only on the primary"

echo "powering off node $node (docker kill) at $(date +%T)"
docker kill "$node" >/dev/null
cut_done=""
sleep 1
kill "$writer_pid" 2>/dev/null || true
writer_pid=""
cp "$WDIR/writer.log" docs/evidence/ADR1-degraded-writer.log
acked_total=$(grep -c '^ack' "$WDIR/writer.log" || true)
echo "acknowledged writes in total: $acked_total"

echo "holding the node down for ${HOLD_S} s and watching whether a replica promotes itself"
t0=$SECONDS
promoted=""
while [ $((SECONDS - t0)) -lt "$HOLD_S" ]; do
  for p in "${peer_pods[@]}"; do
    if [ "$(in_recovery "$p")" = "f" ]; then promoted="$p"; fi
  done
  [ -z "$promoted" ] || break
  sleep 5
done
for p in "${peer_pods[@]}"; do
  c=$(kubectl -n "$NS" logs "$p" -c postgres --since="$((HOLD_S + 20))s" 2>/dev/null | grep -c "not the healthiest node" || true)
  echo "log lines 'not the healthiest node' on $p during the hold: $c"
done
[ -z "$promoted" ] || fail "replica $promoted promoted itself without a primary and without a sync standby; acknowledged writes can be lost"
pass "no replica promoted itself during ${HOLD_S} s (Patroni refuses to fail over to a non-synchronous replica)"

echo "starting node $node again at $(date +%T)"
docker start "$node" >/dev/null
start_ms=$(now_ms)
wp=""
for _ in $(seq 1 90); do
  if wp=$(writable_pod) && psql_pod "$wp" "insert into degraded_probe(n) values (100000) on conflict do nothing" >/dev/null 2>&1; then break; fi
  wp=""
  sleep 3
done
[ -n "$wp" ] || fail "no writable primary came back after the node was restarted"
echo "MEASURED: seconds from restarting the node to a writable primary: $(( ($(now_ms) - start_ms) / 1000 ))"
echo "writable primary after the restart: $wp (the old primary was $leader)"
pass "a writable primary is back without any manual step"

psql_pod "$wp" "select n from degraded_probe" > "$WDIR/present.txt"
awk 'NR==FNR { p[$1]=1; next } $1=="ack" && !($2 in p) { print $2 }' "$WDIR/present.txt" "$WDIR/writer.log" > "$WDIR/lost.txt"
lost=$(wc -l < "$WDIR/lost.txt")
echo "acknowledged writes: $acked_total, rows on the new primary: $(wc -l < "$WDIR/present.txt"), acknowledged writes missing: $lost"
[ "$lost" = 0 ] || fail "$lost acknowledged write(s) are missing after recovery"
pass "no acknowledged write was lost"

wait_healthy 600 || { cluster_table || true; fail "cluster did not return to 1 leader + 2 streaming replicas"; }
cluster_table
want=$(psql_pod "$wp" "select count(*) from degraded_probe")
for p in pg-ha-0 pg-ha-1 pg-ha-2; do
  ok=""
  for _ in $(seq 1 10); do
    c=$(psql_pod "$p" "select count(*) from degraded_probe" || true)
    if [ "$c" = "$want" ]; then ok=yes; break; fi
    sleep 3
  done
  echo "rows on $p: ${c:-?} (expected $want)"
  [ -n "$ok" ] || fail "$p does not match the primary after recovery"
done
pass "all three nodes hold the same rows"

restored=""
names=""
cur=$(writable_pod)
for _ in $(seq 1 30); do
  names=$(psql_pod "$cur" "show synchronous_standby_names" || true)
  if [ -n "$names" ]; then restored=yes; break; fi
  sleep 4
done
[ -n "$restored" ] || fail "synchronous mode did not come back after the replicas returned"
pass "synchronous mode came back on its own (synchronous_standby_names=$names)"

n=$(writable_primaries)
[ "$n" = 1 ] || fail "$n pods accept writes, expected exactly 1"
pass "exactly one pod accepts writes"
echo "ALL CHECKS PASSED"
