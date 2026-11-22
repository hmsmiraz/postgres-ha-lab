#!/usr/bin/env bash
# BK-4: backups are verified automatically. The script of the backup CronJob (ConfigMap pgbackrest-cronjob-scripts) runs
# "pgbackrest verify --output=text --verbose" after each backup and fails the Job unless the exit code is 0 and the report has the
# line "status: ok" (ADR-0002 amendment 2). pgBackRest 2.60.0 verify exits 0 even when it reports "status: error", and prints nothing
# unless --output=text is given. SPEC: "pgbackrest verify plus the restore test in RS-3".
# Checked here: pg-ha healthy, the CronJob exists, docs/evidence/RS-3.txt ends with ALL CHECKS PASSED, planted-input controls (leak
# scanner; the script matcher accepts the new verify command and rejects a backup command and the old verify form; the ok-line
# matcher accepts "status: ok" and rejects "status: error" and a backup line with "status: valid"), the live ConfigMap script runs
# verify --output=text --verbose and tests for "status: ok", the newest full backup is younger than 6 days (so the Jobs make
# incremental backups and no full backup expires); Job 1 completes, adds exactly one incremental backup, logs "verify ok" once and
# its log holds one "status: ok" line; a direct verify in a pg pod exits 0 and prints "status: ok"; a direct verify of a backup set
# that does not exist prints "status: error" and no "status: ok" (its exit code is only reported, it is 0); Job 2 with VERIFY_SET set
# to that set fails, logs "verify FAILED" once, never "verify ok", and still added one incremental backup; no secret value in the logs.
# Left behind on purpose: 2 incremental backups (no full backup is made, so retention expires nothing).
# Not covered: a damaged backup or archive file (only the missing-set error is produced), verify of a large repository, a scheduled
# run, a change of wording in another pgBackRest version (it would fail the Job, the safe direction).
# Leak scans use grep -c, never "producer | grep -q".
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source tests/lib/probe.sh

CJ=pgbackrest-backup
BAD_SET=19990101-000000F
VARGS=(verify --output=text --verbose)
VCMD="${VARGS[*]}"
k() { kubectl -n "$NS" "$@"; }

umask 077
work=$(mktemp -d)
# shellcheck disable=SC2329
cleanup() {
  rm -rf "$work"
  kubectl -n "$NS" delete job -l app=bk-verify-test --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

info_json() {
  local p out
  for p in pg-ha-0 pg-ha-1 pg-ha-2; do
    if out=$(timeout 60 kubectl -n "$NS" exec "$p" -c postgres -- pgbackrest --stanza=pg-ha info --output=json </dev/null 2>/dev/null); then
      if [ -n "$out" ]; then echo "$out"; return 0; fi
    fi
  done
  return 1
}
count_type() { jq --arg t "$2" '[.[0].backup[]? | select(.type == $t)] | length' <<<"$1"; }
has_ok() { grep -c -x 'status: ok' <<<"$1" || true; }
has_err() { grep -c -x 'status: error' <<<"$1" || true; }

make_job() {
  local name=$1 kv key val filter
  shift
  # shellcheck disable=SC2016
  filter='{apiVersion:"batch/v1",kind:"Job",metadata:{name:$name,namespace:"pg-ha",labels:{app:"bk-verify-test"}},spec:.spec.jobTemplate.spec}'
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
RESULT=""
LOG=""
run_job() {
  local name=$1
  shift
  make_job "$name" "$@"
  RESULT=$(wait_job "$name" 900)
  LOG=$(k logs "job/$name" --all-containers 2>&1 || true)
  printf '%s\n' "$LOG" >>"$work/logs"
  echo "INFO: $name result=$RESULT, log lines=$(grep -c '' <<<"$LOG" || true)"
}

echo "date: $(date -u +%FT%TZ)"
k get sts pg-ha >/dev/null 2>&1 || fail "StatefulSet pg-ha is missing"
wait_healthy 120 || fail "Patroni does not report 1 leader and 2 streaming replicas"
pass "pg-ha healthy: 1 leader and 2 streaming replicas"
k get cronjob "$CJ" >/dev/null 2>&1 || fail "CronJob $CJ does not exist (BK-2)"
pass "CronJob $CJ exists"
[ -s docs/evidence/RS-3.txt ] || fail "docs/evidence/RS-3.txt does not exist or is empty (the restore test of RS-3 is part of BK-4)"
[ "$(tail -n 1 docs/evidence/RS-3.txt)" = "ALL CHECKS PASSED" ] || fail "docs/evidence/RS-3.txt does not end with ALL CHECKS PASSED"
pass "the RS-3 restore test evidence exists and ends with ALL CHECKS PASSED"

sk=$(k get secret objstore-credentials -o json | jq -r '.data["secret-access-key"] // empty' | base64 -d)
kl=$(k get secret pgbackrest-tls-client -o json | jq -r '.data["tls.key"] // empty' | base64 -d | sed -n 2p)
[ -n "$sk" ] || fail "the secret access key could not be read"
[ -n "$kl" ] || fail "no key line could be read for the leak control"
printf '%s\n%s\n' "$sk" "$kl" >"$work/pat"
[ "$(grep -F -c -f "$work/pat" <<<"control line with $sk inside" || true)" -eq 1 ] || fail "control: the scanner did not fire on a planted secret"
[ "$(grep -F -c -f "$work/pat" <<<"control line with $kl inside" || true)" -eq 1 ] || fail "control: the scanner did not fire on a planted key line"
planted_new="    vout=\$(pgbackrest --stanza=x verify --output=text --verbose) || vrc=\$?"
planted_bk="    pgbackrest --stanza=x --type=incr backup"
planted_old="    if pgbackrest --stanza=x verify; then"
[ "$(grep -c -F "$VCMD" <<<"$planted_new" || true)" -eq 1 ] || fail "control: the script matcher did not fire on the new verify command"
[ "$(grep -c -F "$VCMD" <<<"$planted_bk" || true)" -eq 0 ] || fail "control: the script matcher also matches a backup command"
[ "$(grep -c -F "$VCMD" <<<"$planted_old" || true)" -eq 0 ] || fail "control: the script matcher also matches the old verify form"
[ "$(has_ok $'stanza: pg-ha\nstatus: ok\n  backup: 1F, status: valid')" = 1 ] || fail "control: the ok-line matcher did not fire on a good report"
[ "$(has_ok $'stanza: pg-ha\nstatus: error\n  backup set x is not valid')" = 0 ] || fail "control: the ok-line matcher accepts an error report"
[ "$(has_ok $'  backup: 1F, status: valid')" = 0 ] || fail "control: the ok-line matcher accepts a backup line"
[ "$(has_err $'stanza: pg-ha\nstatus: error\n  backup set x is not valid')" = 1 ] || fail "control: the error-line matcher did not fire on an error report"
pass "controls: the leak scanner fires, the script matcher rejects a backup command and the old verify form, and the ok-line and error-line matchers tell good from bad reports"

scr=$(k get configmap pgbackrest-cronjob-scripts -o json | jq -r '.data["backup-cronjob.sh"] // empty')
[ -n "$scr" ] || fail "the ConfigMap pgbackrest-cronjob-scripts holds no backup-cronjob.sh"
[ "$(grep -c -F "$VCMD" <<<"$scr" || true)" -ge 1 ] || fail "the backup CronJob script does not run pgbackrest $VCMD (ADR-0002 amendment 2 is not implemented yet)"
[ "$(grep -c -F 'status: ok' <<<"$scr" || true)" -ge 1 ] || fail "the backup CronJob script does not test the report for the line status: ok"
pass "the backup CronJob script runs pgbackrest $VCMD and tests the report for status: ok"

k delete job -l app=bk-verify-test --ignore-not-found --wait=true >/dev/null
info0=$(info_json) || fail "cannot read pgbackrest info"
f0=$(count_type "$info0" full)
i0=$(count_type "$info0" incr)
stop=$(jq '[.[0].backup[] | select(.type == "full") | .timestamp.stop] | max' <<<"$info0")
{ [ -n "$stop" ] && [ "$stop" != null ]; } || fail "could not read the stop time of the newest full backup"
age=$(($(date +%s) - stop))
[ "$age" -lt 518400 ] || fail "the newest full backup is $age s old (limit 518400 s): a Job would make a full backup and expire one, so the test refuses to run"
echo "INFO: baseline full=$f0 incr=$i0, the newest full backup is $age s old"
pass "the newest full backup is younger than 6 days, so the Jobs make incremental backups and nothing expires"

run_job bk-verify-test-1
[ "$RESULT" = complete ] || { printf '%s\n' "$LOG" | tail -n 8; fail "job 1 ended with $RESULT"; }
info1=$(info_json) || fail "cannot read pgbackrest info after job 1"
f1=$(count_type "$info1" full)
i1=$(count_type "$info1" incr)
{ [ "$f1" = "$f0" ] && [ "$i1" = $((i0 + 1)) ]; } || fail "job 1 should add exactly one incremental backup (full $f0 to $f1, incr $i0 to $i1)"
[ "$(grep -c 'backup-cronjob: verify ok' <<<"$LOG" || true)" = 1 ] || fail "the job 1 log does not say verify ok exactly once"
[ "$(grep -c 'backup-cronjob: type=incr' <<<"$LOG" || true)" = 1 ] || fail "the job 1 log does not say type=incr exactly once"
[ "$(grep -c 'verify FAILED' <<<"$LOG" || true)" = 0 ] || fail "the job 1 log says verify FAILED"
[ "$(has_ok "$LOG")" = 1 ] || fail "the job 1 log does not hold exactly one status: ok line (the verify report)"
pass "job 1 added one incremental backup (incr $i0 to $i1), logged the verify report with status: ok and verify ok"

rcv=0
outv=$(timeout 300 kubectl -n "$NS" exec pg-ha-2 -c postgres -- pgbackrest --stanza=pg-ha "${VARGS[@]}" </dev/null 2>&1) || rcv=$?
[ "$rcv" = 0 ] || { printf '%s\n' "$outv" | tail -n 6; fail "a direct pgbackrest verify exited $rcv"; }
[ "$(has_ok "$outv")" = 1 ] || fail "a direct pgbackrest verify did not print exactly one status: ok line"
pass "a direct pgbackrest verify in a pg pod exits 0 and prints status: ok (independent of the script)"

rcm=0
outm=$(timeout 300 kubectl -n "$NS" exec pg-ha-2 -c postgres -- pgbackrest --stanza=pg-ha "${VARGS[@]}" --set="$BAD_SET" </dev/null 2>&1) || rcm=$?
echo "INFO: verify of the missing set $BAD_SET exited $rcm (reported, not asserted)"
[ -n "$outm" ] || fail "the verify of the missing set printed nothing, so the check would prove nothing"
[ "$(has_err "$outm")" = 1 ] || fail "the verify of the missing set did not print exactly one status: error line"
[ "$(has_ok "$outm")" = 0 ] || fail "the verify of the missing set printed status: ok"
pass "a direct verify of a backup set that does not exist prints status: error and no status: ok"

run_job bk-verify-test-2 VERIFY_SET="$BAD_SET"
[ "$RESULT" = failed ] || { printf '%s\n' "$LOG" | tail -n 8; fail "job 2 with a missing verify set ended with $RESULT, expected failed"; }
info2=$(info_json) || fail "cannot read pgbackrest info after job 2"
f2=$(count_type "$info2" full)
i2=$(count_type "$info2" incr)
{ [ "$f2" = "$f1" ] && [ "$i2" = $((i1 + 1)) ]; } || fail "the backup of job 2 should have run (full $f1 to $f2, incr $i1 to $i2)"
[ "$(grep -c 'backup-cronjob: verify FAILED' <<<"$LOG" || true)" = 1 ] || fail "the job 2 log does not say verify FAILED exactly once"
[ "$(grep -c 'backup-cronjob: verify ok' <<<"$LOG" || true)" = 0 ] || fail "the job 2 log also says verify ok"
[ "$(has_err "$LOG")" = 1 ] || fail "the job 2 log does not hold exactly one status: error line"
pass "job 2 with a missing verify set failed, the backup still ran (incr $i1 to $i2), and the log says verify FAILED"

logs=$(cat "$work/logs")
[ -n "$logs" ] || fail "the collected job logs are empty, so the scan would prove nothing"
[ "$(grep -F -c -f "$work/pat" <<<"$logs" || true)" -eq 0 ] || fail "a secret value or key line appears in a job log"
[ "$(grep -F -c 'PRIVATE KEY' <<<"$logs" || true)" -eq 0 ] || fail "a private key marker appears in a job log"
pass "no secret value, key line or private key marker in the job logs"
echo "ALL CHECKS PASSED"
