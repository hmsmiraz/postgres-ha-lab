#!/usr/bin/env bash
# RS-2: point-in-time recovery to a timestamp. scripts/restore-full.sh must read RESTORE_TYPE, RESTORE_TARGET and
# RESTORE_TARGET_ACTION (static check with controls). Then the table rs_pitr is written into the live appdb: 500 "before"
# rows, a pause, the target time taken from the database clock, a pause, 500 "after" rows; the WAL is switched and the test
# waits until the segment is archived. pg-restore is deleted (restore-down.sh) and must not exist; restore-full.sh runs with
# type time, that target and action promote. On all three restored pods: 500 before rows with the live checksum, 0 after rows,
# 500 rows in total (the live table holds 1000, so the check can fail); 1 leader and 2 streaming replicas; archive_mode off;
# the restored timeline is newer than the newest timeline in the live archive and that timeline is unchanged; pg-ha was not
# restarted; no secret value in the restored logs or the script output.
# Left behind on purpose: the table rs_pitr in the live appdb and the running pg-restore namespace (RS-3 reuses it).
# Not covered: a target before the oldest kept backup, a target inside a failover, exclusive targets, recovery types other than
# time. Leak scans use grep -c, never "producer | grep -q".
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source tests/lib/probe.sh

RNS=pg-restore
k() { kubectl -n "$NS" "$@"; }
kr() { kubectl -n "$RNS" "$@"; }

umask 077
work=$(mktemp -d)
# shellcheck disable=SC2329
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

live_sql() {
  local p
  p=$(current_leader)
  timeout 60 kubectl -n "$NS" exec "$p" -c postgres -- psql -U postgres -d appdb -v ON_ERROR_STOP=1 -Atq -c "$1" </dev/null
}
rest_sql() {
  timeout 60 kubectl -n "$RNS" exec "$1" -c postgres -- psql -U postgres -d appdb -v ON_ERROR_STOP=1 -Atq -c "$2" </dev/null
}
rest_state() {
  local p
  for p in pg-restore-0 pg-restore-1 pg-restore-2; do
    timeout 20 kubectl -n "$RNS" exec "$p" -c postgres -- patronictl -c /etc/patroni/patroni.yml list -f json </dev/null 2>/dev/null && return 0
  done
  return 1
}
tl_of() { sed -E 's#.*/##' | { grep -o -E '^[0-9A-F]{8}' || true; } | sort | tail -n 1; }
repo_tl() {
  local p out
  for p in pg-ha-0 pg-ha-1 pg-ha-2; do
    if out=$(timeout 120 kubectl -n "$NS" exec "$p" -c postgres -- pgbackrest repo-ls archive/pg-ha --recurse </dev/null 2>/dev/null); then
      if [ -n "$out" ]; then tl_of <<<"$out"; return 0; fi
    fi
  done
  return 1
}
restarts() { k get pods -l application=pg-ha -o json | jq '[.items[].status.containerStatuses[].restartCount] | add'; }

echo "date: $(date -u +%FT%TZ)"
k get sts pg-ha >/dev/null 2>&1 || fail "StatefulSet pg-ha is missing"
wait_healthy 120 || fail "Patroni does not report 1 leader and 2 streaming replicas in pg-ha"
pass "pg-ha healthy: 1 leader and 2 streaming replicas"
for s in scripts/restore-full.sh scripts/restore-down.sh; do
  [ -x "$s" ] || fail "$s does not exist or is not executable"
done
pass "restore-full.sh and restore-down.sh are present and executable"

[ "$(printf '%s\n' 'x RESTORE_TARGET:- y' | grep -c -E 'RESTORE_TARGET([^A-Z_]|$)' || true)" = 1 ] || fail "control: the static matcher did not fire on planted input"
[ "$(printf '%s\n' 'x RESTORE_TARGET_ACTION y' | grep -c -E 'RESTORE_TARGET([^A-Z_]|$)' || true)" = 0 ] || fail "control: the matcher for RESTORE_TARGET also matches RESTORE_TARGET_ACTION"
pass "controls: the static matcher fires on planted input and tells RESTORE_TARGET from RESTORE_TARGET_ACTION"
for v in RESTORE_TYPE RESTORE_TARGET RESTORE_TARGET_ACTION; do
  [ "$(grep -c -E "${v}([^A-Z_]|\$)" scripts/restore-full.sh || true)" -ge 1 ] || fail "scripts/restore-full.sh does not read $v (point-in-time target not supported yet)"
done
pass "restore-full.sh reads RESTORE_TYPE, RESTORE_TARGET and RESTORE_TARGET_ACTION"

sk=$(k get secret objstore-credentials -o json | jq -r '.data["secret-access-key"] // empty' | base64 -d)
pw=$(k get secret pg-credentials -o json | jq -r '.data["superuser-password"] // empty' | base64 -d)
[ -n "$sk" ] || fail "the secret access key could not be read"
[ -n "$pw" ] || fail "the superuser password could not be read"
printf '%s\n%s\n' "$sk" "$pw" >"$work/pat"
[ "$(grep -F -c -f "$work/pat" <<<"control line with $sk inside" || true)" -eq 1 ] || fail "control: the scanner did not fire on a planted secret key"
[ "$(grep -F -c -f "$work/pat" <<<"control line with $pw inside" || true)" -eq 1 ] || fail "control: the scanner did not fire on a planted password"
[ "$(printf '%s\n' 'x/0000000600000000' | tl_of)" = 00000006 ] || fail "control: the timeline matcher did not fire on planted input"
pass "controls: the leak scanner and the timeline matcher fire on planted input"

r0=$(restarts)
[ -n "$r0" ] || fail "could not read the pg-ha restart counts"
live_sql "drop table if exists rs_pitr; create table rs_pitr(id int primary key, phase text not null); insert into rs_pitr select g, 'before' from generate_series(1,500) g" >/dev/null
sleep 2
target=$(live_sql "select to_char(clock_timestamp() at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00'")
[[ "$target" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}\+00$ ]] || fail "the target time '$target' does not have the expected format"
sleep 2
live_sql "insert into rs_pitr select g, 'after' from generate_series(501,1000) g" >/dev/null
live_before=$(live_sql "select count(*) from rs_pitr where phase = 'before'")
live_after=$(live_sql "select count(*) from rs_pitr where phase = 'after'")
live_md5=$(live_sql "select md5(string_agg(id::text, ',' order by id)) from rs_pitr where phase = 'before'")
{ [ "$live_before" = 500 ] && [ "$live_after" = 500 ]; } || fail "the live table does not hold 500 before and 500 after rows (got $live_before and $live_after)"
pass "live rs_pitr holds 500 before rows and 500 after rows; the target time is $target"

seg=$(live_sql "select pg_walfile_name(pg_current_wal_lsn())")
live_sql "select pg_switch_wal()" >/dev/null
la=""
for _ in $(seq 1 60); do
  la=$(live_sql "select coalesce(last_archived_wal, '') from pg_stat_archiver" || true)
  if [[ "$la" > "$seg" ]] || [ "$la" = "$seg" ]; then break; fi
  sleep 3
done
{ [[ "$la" > "$seg" ]] || [ "$la" = "$seg" ]; } || fail "WAL segment $seg was not archived within 180 s (last archived '$la')"
pass "WAL segment $seg, which holds the after rows, is archived"

tl_before=$(repo_tl) || fail "cannot list the archive of stanza pg-ha"
[ -n "$tl_before" ] || fail "the archive listing holds no timeline, so the archive check would prove nothing"
echo "INFO: newest timeline in the live archive before the restore: $tl_before"

timeout 300 scripts/restore-down.sh >"$work/down.log" 2>&1 || { tail -n 6 "$work/down.log"; fail "restore-down.sh failed"; }
if kubectl get ns "$RNS" >/dev/null 2>&1; then fail "namespace $RNS still exists after restore-down.sh"; fi
pass "$RNS does not exist: the restore starts from an empty namespace"

rc=0
RESTORE_TYPE=time RESTORE_TARGET="$target" RESTORE_TARGET_ACTION=promote timeout 1500 scripts/restore-full.sh >"$work/restore.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { tail -n 12 "$work/restore.log"; fail "restore-full.sh failed (exit $rc)"; }
pass "restore-full.sh finished with exit 0 with a point-in-time target"

ok=no
st=""
for _ in $(seq 1 80); do
  st=$(rest_state || true)
  l=$(jq '[.[] | select(.Role == "Leader")] | length' <<<"$st" 2>/dev/null || echo 0)
  f=$(jq '[.[] | select((.Role == "Replica" or .Role == "Sync Standby") and .State == "streaming")] | length' <<<"$st" 2>/dev/null || echo 0)
  if [ "$l" = 1 ] && [ "$f" = 2 ]; then ok=yes; break; fi
  sleep 3
done
[ "$ok" = yes ] || fail "the restored cluster does not report 1 leader and 2 streaming replicas within 240 s"
pods=$(kr get pods -l application=pg-restore -o json)
[ "$(jq '.items | length' <<<"$pods")" = 3 ] || fail "expected 3 pods in $RNS"
[ "$(jq '[.items[] | select(all(.status.containerStatuses[]?; .ready == true))] | length' <<<"$pods")" = 3 ] || fail "not all 3 restored pods are ready"
pass "3 restored pods are ready; Patroni reports 1 leader and 2 streaming replicas"

for p in pg-restore-0 pg-restore-1 pg-restore-2; do
  got=""
  for _ in $(seq 1 20); do
    got=$(rest_sql "$p" "select count(*) || ':' || count(*) filter (where phase = 'before') || ':' || count(*) filter (where phase = 'after') || ':' || coalesce((select md5(string_agg(id::text, ',' order by id)) from rs_pitr where phase = 'before'), '') from rs_pitr" 2>/dev/null || true)
    if [ "$got" = "500:500:0:$live_md5" ]; then break; fi
    sleep 3
  done
  [ "$got" = "500:500:0:$live_md5" ] || fail "restored data on $p is not as expected (total:before:after '${got%:*}')"
done
pass "on all three restored pods: 500 rows, 500 before rows with the live checksum, 0 after rows"

for p in pg-restore-0 pg-restore-1 pg-restore-2; do
  m=$(rest_sql "$p" "show archive_mode" || true)
  [ "$m" = off ] || fail "archive_mode is '${m:-unknown}' on $p, expected off"
done
pass "archive_mode is off on every restored member"

rl=$(jq -r '.[] | select(.Role == "Leader") | .Member' <<<"$st")
rtl=$(rest_sql "$rl" "select timeline_id from pg_control_checkpoint()")
[[ "$rtl" =~ ^[0-9]+$ ]] || fail "could not read the restored timeline"
rtl_hex=$(printf '%08X' "$rtl")
tl_after=$(repo_tl) || fail "cannot list the archive after the restore"
echo "INFO: restored timeline $rtl_hex, newest live archive timeline before $tl_before and after $tl_after"
[[ "$rtl_hex" > "$tl_before" ]] || fail "the restored cluster did not move to a newer timeline, so the archive check proves nothing"
[ "$tl_after" = "$tl_before" ] || fail "the newest timeline in the live archive changed from $tl_before to $tl_after: the restored cluster wrote into the repository"
pass "the restored cluster is on a newer timeline and the live archive got no newer timeline"

r1=$(restarts)
[ "$r1" = "$r0" ] || fail "the pg-ha restart counts changed from $r0 to $r1"
pass "pg-ha was not restarted by the restore"

logs=""
for p in pg-restore-0 pg-restore-1 pg-restore-2; do
  logs+=$(kr logs "$p" --all-containers 2>&1 || true)$'\n'
done
logs+=$(cat "$work/restore.log")
[ -n "$logs" ] || fail "the collected logs are empty, so the scan would prove nothing"
[ "$(grep -F -c -f "$work/pat" <<<"$logs" || true)" -eq 0 ] || fail "a secret value appears in a restored pod log or in the restore script output"
pass "no secret value in the restored pod logs or the restore script output"
echo "ALL CHECKS PASSED"
