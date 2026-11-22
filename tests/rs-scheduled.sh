#!/usr/bin/env bash
# RS-3 (on demand, ADR-0006, single-pod option): scripts/restore-test.sh restores the latest backup plus the archived WAL into one
# scratch Postgres pod in the fixed namespace pg-restore (emptyDir data, plain Postgres without Patroni, archiving off), waits for
# the end of recovery, runs a data check given by the caller, and removes the pod unless RESTORE_TEST_KEEP=1. The file keeps its
# SPEC name (rs-scheduled.sh) although the test is on demand.
# Checked here: pg-ha healthy, the script and its pod manifest exist, planted-input controls; the table rs_scratch (300 rows) is
# written into the live appdb and its WAL is archived; the script runs with the kept pod; independently of the script: the pod is
# ready, recovery has ended, the checksum equals the live one (control: a changed-value checksum matches its live twin and
# differs from the plain one), archive_mode is off, the scratch timeline is newer than the newest live archive timeline and that
# timeline is unchanged, pg-ha was not restarted, the 3-pod cluster in pg-restore is unchanged; negative control: with a wrong
# expected value the script must fail and must remove its pod; no secret value in the script output or the pod logs.
# Left behind on purpose: the table rs_scratch in the live appdb. The test makes no backup, so retention expires nothing.
# Not covered: a scheduled run, production-sized data, a restore when the archive lacks WAL, two restores at once, pg_amcheck.
# Leak scans use grep -c, never "producer | grep -q".
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source tests/lib/probe.sh

RNS=pg-restore
POD=pg-restore-test
SUM_SQL="select count(*) || ':' || md5(string_agg(id::text || ':' || v, ',' order by id)) from rs_scratch"
CTL_SQL="select count(*) || ':' || md5(string_agg(id::text || ':' || v || 'x', ',' order by id)) from rs_scratch"
k() { kubectl -n "$NS" "$@"; }
kr() { kubectl -n "$RNS" "$@"; }

umask 077
work=$(mktemp -d)
# shellcheck disable=SC2329
cleanup() {
  kubectl -n "$RNS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

live_sql() {
  local p
  p=$(current_leader)
  timeout 60 kubectl -n "$NS" exec "$p" -c postgres -- psql -U postgres -d appdb -v ON_ERROR_STOP=1 -Atq -c "$1" </dev/null
}
scratch_sql() {
  timeout 60 kubectl -n "$RNS" exec "$POD" -c postgres -- psql -h /run/postgresql -U postgres -d appdb -v ON_ERROR_STOP=1 -Atq -c "$1" </dev/null
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
cluster_uids() { { kubectl -n "$RNS" get pods -l application=pg-restore -o json 2>/dev/null || true; } | jq -r '[.items[]?.metadata.uid] | sort | join(",")'; }
scratch_pods() { kubectl -n "$RNS" get pods -o json 2>/dev/null | jq --arg p "$POD" '[.items[] | select(.metadata.name == $p)] | length'; }

echo "date: $(date -u +%FT%TZ)"
k get sts pg-ha >/dev/null 2>&1 || fail "StatefulSet pg-ha is missing"
wait_healthy 120 || fail "Patroni does not report 1 leader and 2 streaming replicas in pg-ha"
pass "pg-ha healthy: 1 leader and 2 streaming replicas"
[ -x scripts/restore-test.sh ] || fail "scripts/restore-test.sh does not exist or is not executable"
[ -f k8s/restore/60-restore-test-pod.yaml ] || fail "k8s/restore/60-restore-test-pod.yaml does not exist"
pass "restore-test.sh and its pod manifest are present"

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
u0=$(cluster_uids)
live_sql "drop table if exists rs_scratch; create table rs_scratch(id int primary key, v text not null); insert into rs_scratch select g, md5(g::text) from generate_series(1,300) g" >/dev/null
live_sum=$(live_sql "$SUM_SQL")
live_ctl=$(live_sql "$CTL_SQL")
[ "${live_sum%%:*}" = 300 ] || fail "the live rs_scratch table does not have 300 rows (got '${live_sum%%:*}')"
[ "$live_ctl" != "$live_sum" ] || fail "control: the changed-value checksum equals the plain checksum, so the data check could not fail"
seg=$(live_sql "select pg_walfile_name(pg_current_wal_lsn())")
live_sql "select pg_switch_wal()" >/dev/null
la=""
for _ in $(seq 1 60); do
  la=$(live_sql "select coalesce(last_archived_wal, '') from pg_stat_archiver" || true)
  if [[ "$la" > "$seg" ]] || [ "$la" = "$seg" ]; then break; fi
  sleep 3
done
{ [[ "$la" > "$seg" ]] || [ "$la" = "$seg" ]; } || fail "WAL segment $seg was not archived within 180 s (last archived '$la')"
pass "live rs_scratch written (300 rows, the changed-value control differs); WAL segment $seg is archived"

tl_before=$(repo_tl) || fail "cannot list the archive of stanza pg-ha"
[ -n "$tl_before" ] || fail "the archive listing holds no timeline, so the archive check would prove nothing"
echo "INFO: newest timeline in the live archive before the restore test: $tl_before"

rc=0
RESTORE_TEST_KEEP=1 RESTORE_TEST_SQL="$SUM_SQL" RESTORE_TEST_EXPECT="$live_sum" timeout 900 scripts/restore-test.sh >"$work/ok.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { tail -n 12 "$work/ok.log"; fail "restore-test.sh failed (exit $rc)"; }
pass "restore-test.sh finished with exit 0 and kept the scratch pod for inspection"

[ "$(kr get pod "$POD" -o json | jq -r '.status.containerStatuses[0].ready')" = true ] || fail "the scratch pod is not ready"
[ "$(scratch_sql "select pg_is_in_recovery()")" = f ] || fail "the scratch instance is still in recovery"
got=$(scratch_sql "$SUM_SQL")
[ "$got" = "$live_sum" ] || fail "the restored data differs from the live data (row count '${got%%:*}')"
ctl=$(scratch_sql "$CTL_SQL")
[ "$ctl" = "$live_ctl" ] || fail "control: the changed-value checksum on the scratch instance differs from its live twin"
[ "$ctl" != "$got" ] || fail "control: the changed-value checksum equals the plain checksum"
pass "the scratch instance is ready, recovery has ended, and row count 300 and checksum equal the live ones (control matches)"

m=$(scratch_sql "show archive_mode" || true)
[ "$m" = off ] || fail "archive_mode is '${m:-unknown}' on the scratch instance, expected off"
rtl=$(scratch_sql "select timeline_id from pg_control_checkpoint()")
[[ "$rtl" =~ ^[0-9]+$ ]] || fail "could not read the scratch timeline"
rtl_hex=$(printf '%08X' "$rtl")
tl_after=$(repo_tl) || fail "cannot list the archive after the restore test"
echo "INFO: scratch timeline $rtl_hex, newest live archive timeline before $tl_before and after $tl_after"
[[ "$rtl_hex" > "$tl_before" ]] || fail "the scratch instance did not move to a newer timeline, so the archive check proves nothing"
[ "$tl_after" = "$tl_before" ] || fail "the newest timeline in the live archive changed from $tl_before to $tl_after: the scratch instance wrote into the repository"
pass "archive_mode is off, the scratch instance is on a newer timeline, and the live archive got no newer timeline"

r1=$(restarts)
[ "$r1" = "$r0" ] || fail "the pg-ha restart counts changed from $r0 to $r1"
u1=$(cluster_uids)
[ "$u1" = "$u0" ] || fail "the 3-pod cluster in $RNS changed during the restore test"
pass "pg-ha was not restarted and the 3-pod cluster in $RNS is unchanged"

plog=$(kr logs "$POD" --all-containers 2>&1 || true)
kr delete pod "$POD" --wait=true --timeout=120s >/dev/null || fail "could not delete the scratch pod"
[ "$(scratch_pods)" = 0 ] || fail "the scratch pod is still there after the delete"

rcn=0
RESTORE_TEST_SQL="$SUM_SQL" RESTORE_TEST_EXPECT="0:bad" timeout 900 scripts/restore-test.sh >"$work/neg.log" 2>&1 || rcn=$?
[ "$rcn" != 0 ] || fail "negative control: restore-test.sh passed with a wrong expected value"
[ -s "$work/neg.log" ] || fail "negative control: the failed run printed nothing, so the control proves nothing"
[ "$(scratch_pods)" = 0 ] || fail "the failed run left the scratch pod behind"
pass "negative control: with a wrong expected value the script fails and removes its pod"

logs="$plog"$'\n'"$(cat "$work/ok.log")"$'\n'"$(cat "$work/neg.log")"
[ -n "$plog" ] || fail "the scratch pod log is empty, so the scan would prove nothing"
[ "$(grep -F -c -f "$work/pat" <<<"$logs" || true)" -eq 0 ] || fail "a secret value appears in the script output or the scratch pod log"
pass "no secret value in the script output or the scratch pod log"
echo "ALL CHECKS PASSED"
