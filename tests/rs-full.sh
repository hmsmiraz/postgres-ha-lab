#!/usr/bin/env bash
# RS-1: full cluster restore into an empty namespace by one script. scripts/restore-full.sh creates the fixed scratch
# namespace pg-restore, copies the Secrets it needs from pg-ha without printing them, and brings up a 3-pod Patroni cluster
# whose bootstrap runs pgbackrest restore from the repository of the live stanza pg-ha, with archiving off.
# Checked here: pg-ha healthy, the BK-2 CronJob and both scripts exist, planted-input controls, then the sentinel table
# rs_sentinel (1000 rows) is written into the live appdb and a full backup is made through the CronJob template; pg-restore is
# deleted (restore-down.sh) and must not exist; restore-full.sh runs; 3 pods ready, 1 leader and 2 streaming replicas; only
# the expected three Secrets exist and objstore-ca holds only ca.crt; row count and checksum equal the live ones on all three
# pods (control: a changed-value checksum equals its live twin and differs from the plain one); archive_mode is off on every
# member; the restored timeline is newer than the repository's newest timeline and that newest timeline is unchanged (nothing
# was written into the live archive); the pg-ha restart counts are unchanged; no secret value in the restored logs.
# Left behind on purpose: the table rs_sentinel in the live appdb (RS-2 needs it), the new full backup (the third full backup
# expires the oldest one, retention-full=2), and the running pg-restore namespace (scripts/restore-down.sh deletes it).
# Not covered: restore of a backup older than the newest, restore with an archive that holds a newer timeline, two restores at
# the same time. Leak scans use grep -c, never "producer | grep -q".
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source tests/lib/probe.sh

RNS=pg-restore
CJ=pgbackrest-backup
SUM_SQL="select count(*) || ':' || md5(string_agg(id::text || ':' || v, ',' order by id)) from rs_sentinel"
CTL_SQL="select count(*) || ':' || md5(string_agg(id::text || ':' || v || 'x', ',' order by id)) from rs_sentinel"
k() { kubectl -n "$NS" "$@"; }
kr() { kubectl -n "$RNS" "$@"; }

umask 077
work=$(mktemp -d)
# shellcheck disable=SC2329
cleanup() {
  rm -rf "$work"
  kubectl -n "$NS" delete job -l app=rs-full-test --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
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
info_json() {
  local p out
  for p in pg-ha-0 pg-ha-1 pg-ha-2; do
    if out=$(timeout 60 kubectl -n "$NS" exec "$p" -c postgres -- pgbackrest --stanza=pg-ha info --output=json </dev/null 2>/dev/null); then
      if [ -n "$out" ]; then echo "$out"; return 0; fi
    fi
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
make_job() {
  local name=$1 kv key val filter
  shift
  # shellcheck disable=SC2016
  filter='{apiVersion:"batch/v1",kind:"Job",metadata:{name:$name,namespace:"pg-ha",labels:{app:"rs-full-test"}},spec:.spec.jobTemplate.spec}'
  for kv in "$@"; do
    key=${kv%%=*}
    val=${kv#*=}
    filter="$filter | .spec.template.spec.containers[0].env |= (map(select(.name != \"$key\")) + [{name:\"$key\",value:\"$val\"}])"
  done
  k get cronjob "$CJ" -o json | jq --arg name "$name" "$filter" | k apply -f - >/dev/null
}
wait_job() {
  local name=$1 deadline=$((SECONDS + $2)) s f
  while [ "$SECONDS" -lt "$deadline" ]; do
    s=$(k get job "$name" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
    f=$(k get job "$name" -o jsonpath='{.status.failed}' 2>/dev/null || true)
    if [ "${s:-0}" = 1 ]; then echo complete; return 0; fi
    if [ "${f:-0}" -ge 1 ]; then echo failed; return 0; fi
    sleep 3
  done
  echo timeout
}

echo "date: $(date -u +%FT%TZ)"
k get sts pg-ha >/dev/null 2>&1 || fail "StatefulSet pg-ha is missing"
wait_healthy 120 || fail "Patroni does not report 1 leader and 2 streaming replicas in pg-ha"
pass "pg-ha healthy: 1 leader and 2 streaming replicas"
k get cronjob "$CJ" >/dev/null 2>&1 || fail "CronJob $CJ does not exist (BK-2)"
pass "CronJob $CJ exists"
for s in scripts/restore-full.sh scripts/restore-down.sh; do
  [ -x "$s" ] || fail "$s does not exist or is not executable"
done
pass "restore-full.sh and restore-down.sh are present and executable"

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
live_sql "drop table if exists rs_sentinel; create table rs_sentinel(id int primary key, v text not null); insert into rs_sentinel select g, md5(g::text) from generate_series(1,1000) g" >/dev/null
live_sum=$(live_sql "$SUM_SQL")
live_ctl=$(live_sql "$CTL_SQL")
[ "${live_sum%%:*}" = 1000 ] || fail "the live sentinel table does not have 1000 rows (got '${live_sum%%:*}')"
[ "$live_ctl" != "$live_sum" ] || fail "control: the changed-value checksum equals the plain checksum, so the data check could not fail"
t_sentinel=$(date +%s)
pass "sentinel table rs_sentinel written in the live appdb: 1000 rows; the changed-value control differs"

k delete job -l app=rs-full-test --ignore-not-found --wait=true >/dev/null
make_job rs-full-backup BACKUP_FULL_INTERVAL_SECONDS=0
res=$(wait_job rs-full-backup 600)
[ "$res" = complete ] || fail "the full backup job ended with $res"
info=$(info_json) || fail "cannot read pgbackrest info"
last_stop=$(jq '[.[0].backup[] | select(.type == "full") | .timestamp.stop] | max' <<<"$info")
{ [ -n "$last_stop" ] && [ "$last_stop" != null ]; } || fail "could not read the stop time of the newest full backup"
[ "$last_stop" -ge "$t_sentinel" ] || fail "the newest full backup ended before the sentinel was written"
echo "INFO: full backups in the repository: $(jq '[.[0].backup[] | select(.type == "full")] | length' <<<"$info")"
pass "a full backup made after the sentinel exists in the repository"

live_tl=$(live_sql "select timeline_id from pg_control_checkpoint()")
tl_before=$(repo_tl) || fail "cannot list the archive of stanza pg-ha"
[ -n "$tl_before" ] || fail "the archive listing holds no timeline, so the archive check would prove nothing"
echo "INFO: live timeline $live_tl, newest timeline in the repository before the restore: $tl_before"

timeout 300 scripts/restore-down.sh >"$work/down.log" 2>&1 || { tail -n 6 "$work/down.log"; fail "restore-down.sh failed"; }
if kubectl get ns "$RNS" >/dev/null 2>&1; then fail "namespace $RNS still exists after restore-down.sh"; fi
pass "$RNS does not exist: the restore starts from an empty namespace"

rc=0
timeout 1500 scripts/restore-full.sh >"$work/restore.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { tail -n 12 "$work/restore.log"; fail "restore-full.sh failed (exit $rc)"; }
pass "restore-full.sh finished with exit 0"

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

[ "$(kr get secret -o json | jq -r '[.items[].metadata.name] | sort | join(",")')" = "objstore-ca,objstore-credentials,pg-credentials" ] || fail "$RNS must hold exactly the Secrets objstore-ca, objstore-credentials and pg-credentials"
[ "$(kr get secret objstore-ca -o json | jq -c '[.data | keys[]] | sort')" = '["ca.crt"]' ] || fail "objstore-ca must hold only ca.crt"
pass "$RNS holds exactly the three expected Secrets, and objstore-ca holds only ca.crt (no private key copied)"

rl=$(jq -r '.[] | select(.Role == "Leader") | .Member' <<<"$st")
[ -n "$rl" ] || fail "no leader name in the restored cluster"
for p in pg-restore-0 pg-restore-1 pg-restore-2; do
  got=""
  for _ in $(seq 1 20); do
    got=$(rest_sql "$p" "$SUM_SQL" 2>/dev/null || true)
    if [ "$got" = "$live_sum" ]; then break; fi
    sleep 3
  done
  [ "$got" = "$live_sum" ] || fail "restored data on $p differs from the live data (row count '${got%%:*}')"
done
pass "row count 1000 and checksum equal the live ones on all three restored pods"

ctl=$(rest_sql "$rl" "$CTL_SQL")
[ "$ctl" = "$live_ctl" ] || fail "control: the changed-value checksum on the restored leader differs from its live twin"
[ "$ctl" != "$live_sum" ] || fail "control: the changed-value checksum equals the plain checksum"
pass "control: the changed-value checksum matches its live twin and differs from the plain checksum"

for p in pg-restore-0 pg-restore-1 pg-restore-2; do
  m=$(rest_sql "$p" "show archive_mode" || true)
  [ "$m" = off ] || fail "archive_mode is '${m:-unknown}' on $p, expected off"
done
pass "archive_mode is off on every restored member"

rtl=$(rest_sql "$rl" "select timeline_id from pg_control_checkpoint()")
[[ "$rtl" =~ ^[0-9]+$ ]] || fail "could not read the restored timeline"
rtl_hex=$(printf '%08X' "$rtl")
tl_after=$(repo_tl) || fail "cannot list the archive after the restore"
echo "INFO: restored timeline $rtl_hex, newest repository timeline before $tl_before and after $tl_after"
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
