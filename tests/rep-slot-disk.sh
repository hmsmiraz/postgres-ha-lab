#!/usr/bin/env bash
# REP-3 drill: a replica that stops consuming WAL must not be able to fill the primary's disk.
# max_slot_wal_keep_size is lowered to 128MB for the drill (via Patroni) and restored afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source tests/lib/probe.sh

CAP=128MB
ORIG=1GB
ROUNDS=24
node=""; cut_done=""; cap_changed=""

ctl() { timeout 60 kubectl -n "$NS" exec pg-ha-0 -c postgres -- patronictl -c /etc/patroni/patroni.yml "$@"; }
psql_pod() { timeout 30 kubectl -n "$NS" exec "$1" -c postgres -- psql -U postgres -d appdb -Atq -v ON_ERROR_STOP=1 -c "$2"; }
wal_mb() { timeout 20 kubectl -n "$NS" exec "$leader" -c postgres -- sh -c 'du -sm /pgdata/data/pg_wal | cut -f1'; }
slot_row() { psql_pod "$leader" "select coalesce(wal_status,'-')||'|'||coalesce(invalidation_reason,'-')||'|'||active from pg_replication_slots where slot_name = '$slot'"; }

cleanup() {
  if [ -n "$cut_done" ]; then docker exec "$node" nft delete table ip pgha_fence 2>/dev/null || true; fi
  if [ -n "$cap_changed" ]; then
    echo "cleanup: restoring max_slot_wal_keep_size=$ORIG"
    ctl edit-config -p "max_slot_wal_keep_size=$ORIG" --force >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "date: $(date -u +%FT%TZ)"
wait_healthy 120 || fail "cluster is not healthy before the test"
leader=$(current_leader)
target=$(cluster_json | jq -r '.[] | select(.Role == "Replica") | .Member' | head -1)
[ -n "$target" ] || fail "no async replica to use for the drill"
slot=${target//-/_}
node=$(kubectl -n "$NS" get pod "$leader" -o jsonpath='{.spec.nodeName}')
leader_ip=$(kubectl -n "$NS" get pod "$leader" -o jsonpath='{.status.podIP}')
target_ip=$(kubectl -n "$NS" get pod "$target" -o jsonpath='{.status.podIP}')
echo "leader: $leader on $node ($leader_ip); drill replica: $target ($target_ip), slot $slot"
echo "slot before: $(slot_row)"
echo "pg_wal size before: $(wal_mb) MB"

ctl edit-config -p "max_slot_wal_keep_size=$CAP" --force >/dev/null
cap_changed=yes
v=""
for _ in $(seq 1 30); do
  v=$(psql_pod "$leader" "show max_slot_wal_keep_size" || true)
  [ "$v" = "$CAP" ] && break
  sleep 2
done
[ "$v" = "$CAP" ] || fail "max_slot_wal_keep_size is '$v', expected $CAP"
pass "max_slot_wal_keep_size lowered to $CAP for the drill"

psql_pod "$leader" "create table if not exists slot_probe(i int)" >/dev/null

echo "cutting $target off from the primary (nftables)"
docker exec "$node" nft add table ip pgha_fence
docker exec "$node" nft "add chain ip pgha_fence isolate { type filter hook forward priority -150 ; policy accept ; }"
docker exec "$node" nft add rule ip pgha_fence isolate ip saddr "$leader_ip" ip daddr "$target_ip" counter drop
docker exec "$node" nft add rule ip pgha_fence isolate ip saddr "$target_ip" ip daddr "$leader_ip" counter drop
cut_done=yes

echo "generating $ROUNDS WAL segments (about $((ROUNDS * 16)) MB) while $target is cut off"
for i in $(seq 1 "$ROUNDS"); do echo "insert into slot_probe values ($i); select pg_switch_wal();"; done \
  | timeout 180 kubectl -n "$NS" exec -i "$leader" -c postgres -- \
      psql -U postgres -d appdb -Atq -v ON_ERROR_STOP=1 >/dev/null \
  || fail "the primary could not keep writing while the replica was cut off"
pass "the primary kept accepting writes while $target was cut off"

echo "slot before checkpoint: $(slot_row)"
size_before=$(wal_mb)
echo "pg_wal size before checkpoint: ${size_before} MB"
psql_pod "$leader" "checkpoint" >/dev/null

seen=""
for _ in $(seq 1 60); do
  row=$(slot_row || true)
  case "$row" in
    lost*|*"|wal_removed|"*) seen="slot invalidated ($row)"; break ;;
    "") seen="slot was dropped (Patroni removes slots whose WAL is lost)"; break ;;
  esac
  sleep 1
done
echo "slot after checkpoint: ${row:-<none>}"
[ -n "$seen" ] || fail "the lagging slot was never invalidated; WAL retention is not capped"
pass "lagging slot was handled by the cap: $seen"

psql_pod "$leader" "checkpoint" >/dev/null
sleep 3
size_after=$(wal_mb)
echo "pg_wal size after checkpoint: ${size_after} MB (was ${size_before} MB)"
[ "$size_after" -le 256 ] || fail "pg_wal is ${size_after} MB, above 256 MB (cap $CAP plus headroom)"
pass "pg_wal stayed bounded: ${size_after} MB (cap $CAP)"

echo "removing the cut"
docker exec "$node" nft delete table ip pgha_fence
cut_done=""
recovered=""
for _ in $(seq 1 30); do
  st=$(cluster_json | jq -r --arg m "$target" '.[] | select(.Member == $m) | .State')
  if [ "$st" = streaming ]; then recovered=yes; break; fi
  sleep 4
done
if [ -n "$recovered" ]; then
  echo "OBSERVATION: $target caught up and is streaming again on its own"
else
  echo "OBSERVATION: $target did NOT recover on its own (state: ${st:-unknown}); the WAL it needs was removed and there is no WAL archive yet"
  echo "running: patronictl reinit pg-ha $target (manual step, recorded as a finding)"
  ctl reinit pg-ha "$target" --force >/dev/null
fi
wait_healthy 400 || { cluster_table || true; fail "cluster did not return to 1 leader + 2 streaming replicas"; }
cluster_table
pass "cluster is back to 1 leader + 2 streaming replicas"

ctl edit-config -p "max_slot_wal_keep_size=$ORIG" --force >/dev/null
cap_changed=""
for _ in $(seq 1 30); do
  v=$(psql_pod "$leader" "show max_slot_wal_keep_size" || true)
  [ "$v" = "$ORIG" ] && break
  sleep 2
done
[ "$v" = "$ORIG" ] || fail "max_slot_wal_keep_size was not restored (it is '$v')"
pass "max_slot_wal_keep_size restored to $ORIG"

n=$(writable_primaries)
[ "$n" = 1 ] || fail "$n pods accept writes, expected exactly 1"
pass "exactly one pod accepts writes"
echo "ALL CHECKS PASSED"
