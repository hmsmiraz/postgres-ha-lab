#!/usr/bin/env bash
# REP-3 drill: a replica that stops consuming WAL must not make the primary keep WAL forever.
# max_slot_wal_keep_size is lowered to 128MB (via Patroni) and restored afterwards.
# The replica is cut off silently (nftables drop). Earlier runs showed the primary's checkpoint
# waits on that replica's walsender (ReplicationSlotDrop) and completes after about 211 s.
# This test measures that wait and the pg_wal growth during it, and checks that the WAL file the
# replica needs is gone from the primary afterwards.
set -Eeuo pipefail
trap 'echo "FAIL: command failed at line $LINENO: $BASH_COMMAND"' ERR
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source tests/lib/probe.sh

CAP=128MB
ORIG=1GB
ROUNDS=24
BLOCK_S=60
HEAL_WAIT_S=240
node=""; cut_done=""; cap_changed=""; ckpt_pid=""
ckpt_dir=$(mktemp -d)

ctl() { timeout 60 kubectl -n "$NS" exec pg-ha-0 -c postgres -- patronictl -c /etc/patroni/patroni.yml "$@"; }
psql_pod() { timeout 30 kubectl -n "$NS" exec "$1" -c postgres -- psql -U postgres -d appdb -Atq -v ON_ERROR_STOP=1 -c "$2"; }
wal_mb() { timeout 20 kubectl -n "$NS" exec "$leader" -c postgres -- sh -c 'du -sm /pgdata/data/pg_wal | cut -f1'; }
slot_row() { psql_pod "$leader" "select coalesce(wal_status,'-')||'|'||coalesce(invalidation_reason,'-')||'|active='||active||'|safe_wal_size='||coalesce(safe_wal_size::text,'-') from pg_replication_slots where slot_name = '$slot'"; }

cleanup() {
  if [ -n "$ckpt_pid" ]; then kill "$ckpt_pid" 2>/dev/null || true; fi
  if [ -n "$cut_done" ]; then docker exec "$node" nft delete table ip pgha_fence 2>/dev/null || true; fi
  if [ -n "$cap_changed" ]; then
    echo "cleanup: restoring max_slot_wal_keep_size=$ORIG"
    ctl edit-config -p "max_slot_wal_keep_size=$ORIG" --force >/dev/null 2>&1 || true
  fi
  rm -rf "$ckpt_dir"
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
need_lsn=$(psql_pod "$target" "select pg_last_wal_replay_lsn()")
need_file=$(psql_pod "$leader" "select pg_walfile_name('$need_lsn')")
echo "leader: $leader on $node ($leader_ip); drill replica: $target ($target_ip), slot $slot"
echo "replica replay position: $need_lsn, WAL file it needs: $need_file"
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

echo "cutting $target off from the primary (nftables) at $(date +%T)"
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

before_row=$(slot_row)
echo "slot after the writes: $before_row"
case "$before_row" in
  unreserved*|lost*) pass "the slot is past the cap (${before_row%%|*})" ;;
  *) fail "the slot is still within the cap: $before_row" ;;
esac

echo "starting CHECKPOINT in the background (client limit 600 s) at $(date +%T)"
(
  s=$SECONDS; rc=0
  timeout 600 kubectl -n "$NS" exec "$leader" -c postgres -- \
    psql -U postgres -Atq -c checkpoint </dev/null >"$ckpt_dir/out" 2>&1 || rc=$?
  echo "rc=$rc after $((SECONDS - s))s" > "$ckpt_dir/done"
) &
ckpt_pid=$!
sleep 5
blocked=$(psql_pod "$leader" "select count(*) from pg_stat_activity where backend_type = 'checkpointer' and wait_event = 'ReplicationSlotDrop'")
echo "checkpointer waiting on ReplicationSlotDrop: $blocked (1 = yes)"
size_start=$(wal_mb)
echo "pg_wal size when the checkpoint started: ${size_start} MB"

echo "primary keeps writing for ${BLOCK_S} s while the checkpoint waits (the cut stays in place)"
t0=$SECONDS; w=0
while [ $((SECONDS - t0)) -lt "$BLOCK_S" ]; do
  w=$((w + 1))
  psql_pod "$leader" "insert into slot_probe values ($((1000 + w))); select pg_switch_wal();" >/dev/null \
    || fail "the primary stopped accepting writes while the checkpoint was waiting"
  sleep 4
done
size_block=$(wal_mb)
if [ -f "$ckpt_dir/done" ]; then echo "NOTE: the checkpoint finished by itself during the cut: $(cat "$ckpt_dir/done")"; fi
pass "the primary kept accepting writes during the wait ($w segments of 16 MB written)"
echo "MEASURED: pg_wal grew from ${size_start} MB to ${size_block} MB in ${BLOCK_S} s while the checkpoint waited"

echo "removing the cut at $(date +%T)"
docker exec "$node" nft delete table ip pgha_fence
cut_done=""
heal_at=$SECONDS
done_ok=""
for _ in $(seq 1 "$HEAL_WAIT_S"); do
  if [ -f "$ckpt_dir/done" ]; then done_ok=yes; break; fi
  sleep 1
done
echo "checkpoint (client view): $(cat "$ckpt_dir/done" 2>/dev/null || echo 'still running')"
[ -n "$done_ok" ] || fail "the checkpoint did not finish within ${HEAL_WAIT_S} s after the cut was removed"
echo "MEASURED: seconds from removing the cut to checkpoint completion: $((SECONDS - heal_at))"
grep -q 'rc=0' "$ckpt_dir/done" || fail "the checkpoint command failed: $(cat "$ckpt_dir/out")"
wait "$ckpt_pid" 2>/dev/null || true
ckpt_pid=""
pass "the checkpoint completed once the dead connection was gone"

gone=""
for _ in $(seq 1 30); do
  c=$(psql_pod "$leader" "select count(*) from pg_ls_waldir() where name = '$need_file'")
  if [ "$c" = 0 ]; then gone=yes; break; fi
  sleep 2
done
echo "slot after the checkpoint: $(slot_row || true)"
[ -n "$gone" ] || fail "the WAL file $need_file the lagging replica needs is still on the primary; retention is not capped"
pass "the WAL file $need_file needed by $target is gone from the primary (retention is capped)"
echo "pg_wal size now: $(wal_mb) MB (informational: Postgres keeps recycled segments)"

recovered=""
st=""
for _ in $(seq 1 60); do
  st=$(cluster_json | jq -r --arg m "$target" '.[] | select(.Member == $m) | .State')
  if [ "$st" = streaming ]; then recovered=yes; break; fi
  sleep 4
done
if [ -n "$recovered" ]; then
  echo "OBSERVATION: $target caught up and is streaming again on its own"
else
  echo "OBSERVATION: $target did NOT recover on its own (state: ${st:-unknown}); the required WAL was removed from the primary"
  echo "running: patronictl reinit pg-ha $target (manual step, recorded as a finding)"
  ctl reinit pg-ha "$target" --force >/dev/null
fi
wait_healthy 400 || { cluster_table || true; fail "cluster did not return to 1 leader + 2 streaming replicas"; }
cluster_table
pass "cluster is back to 1 leader + 2 streaming replicas"
[ -n "$recovered" ] || fail "the lagging replica required reinitialization"

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
