#!/usr/bin/env bash
# BK-2 (live schedule check): patch the CronJob schedule to fire about 3 minutes ahead, wait for a Job owned by the
# CronJob, restore the original schedule, then check the Job, its log, the backup count and the restore.
# This changes spec.schedule of the live CronJob for a few minutes and adds one backup. It prints no secret.
set -euo pipefail
cd "$(dirname "$0")/.."

NS=pg-ha
CJ=pgbackrest-backup
fail=0
pass() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }

orig_schedule=$(kubectl -n "$NS" get cronjob "$CJ" -o jsonpath='{.spec.schedule}')
orig_tz=$(kubectl -n "$NS" get cronjob "$CJ" -o jsonpath='{.spec.timeZone}')
orig_suspend=$(kubectl -n "$NS" get cronjob "$CJ" -o jsonpath='{.spec.suspend}')
if [ -z "$orig_schedule" ]; then echo "cannot read the CronJob, refusing to run"; exit 2; fi
echo "date_utc: $(date -u +%FT%TZ)"
echo "original schedule: $orig_schedule  timeZone: $orig_tz  suspend: $orig_suspend"

now_min=$((10#$(date -u +%H) * 60 + 10#$(date -u +%M)))
if [ "$now_min" -ge 110 ] && [ "$now_min" -le 135 ]; then echo "too close to 02:00 UTC, refusing to run"; exit 2; fi
active=$(kubectl -n "$NS" get cronjob "$CJ" -o json | jq '(.status.active // []) | length')
if [ "$active" -ne 0 ]; then echo "the CronJob has an active Job, refusing to run"; exit 2; fi

set_schedule() {
  kubectl -n "$NS" patch cronjob "$CJ" --type merge -p "$(jq -nc --arg s "$1" '{spec:{schedule:$s}}')" >/dev/null
}
restore() { set_schedule "$orig_schedule" 2>/dev/null || true; }
trap restore EXIT

owned() { # since -> number of Jobs owned by the CronJob and created after $since (JSON on stdin)
  jq --arg cj "$CJ" --arg since "$1" '[.items[] | select(any(.metadata.ownerReferences[]?; .kind == "CronJob" and .name == $cj)) | select(.metadata.creationTimestamp > $since)] | length'
}
count_backups() {
  kubectl -n "$NS" exec pg-ha-2 -c postgres -- pgbackrest --stanza=pg-ha info --output=json | jq '[.[0].backup[]] | length'
}

synth=$(jq -nc --arg n "$CJ" '{items:[{metadata:{creationTimestamp:"2099-01-01T00:00:00Z",ownerReferences:[{kind:"CronJob",name:$n}]}},{metadata:{creationTimestamp:"2099-01-01T00:00:00Z"}}]}')
if [ "$(printf '%s' "$synth" | owned "2026-01-01T00:00:00Z")" = 1 ]; then pass "control: the owned-Job filter counts 1 of 2 in a synthetic list"; else bad "control: the owned-Job filter counts 1 of 2 in a synthetic list"; fi

start=$(date -u +%FT%TZ)
before=$(count_backups)
echo "backups before: $before"
target=$(date -u -d '+3 minutes' '+%-M %-H * * *')
set_schedule "$target"
if [ "$(kubectl -n "$NS" get cronjob "$CJ" -o jsonpath='{.spec.schedule}')" = "$target" ]; then pass "temporary schedule is set ($target)"; else bad "temporary schedule is set ($target)"; fi

jobname=""
for _ in $(seq 1 72); do
  n=$(kubectl -n "$NS" get jobs -o json | owned "$start")
  if [ "$n" -ge 1 ]; then
    jobname=$(kubectl -n "$NS" get jobs -o json | jq -r --arg cj "$CJ" --arg since "$start" '[.items[] | select(any(.metadata.ownerReferences[]?; .kind == "CronJob" and .name == $cj)) | select(.metadata.creationTimestamp > $since)][0].metadata.name')
    break
  fi
  sleep 5
done
restore
if [ "$(kubectl -n "$NS" get cronjob "$CJ" -o jsonpath='{.spec.schedule}')" = "$orig_schedule" ]; then pass "original schedule is restored"; else bad "original schedule is restored (it is NOT; original was: $orig_schedule)"; fi
if [ "$(kubectl -n "$NS" get cronjob "$CJ" -o jsonpath='{.spec.timeZone}')" = "$orig_tz" ] && [ "$(kubectl -n "$NS" get cronjob "$CJ" -o jsonpath='{.spec.suspend}')" = "$orig_suspend" ]; then pass "timeZone and suspend are unchanged"; else bad "timeZone and suspend are unchanged"; fi

if [ -n "$jobname" ] && [ "$jobname" != null ]; then
  pass "the controller created a Job from the CronJob ($jobname)"
  if kubectl -n "$NS" wait --for=condition=complete "job/$jobname" --timeout=600s >/dev/null 2>&1; then pass "the Job completed"; else bad "the Job completed"; fi
  logs=$(kubectl -n "$NS" logs "job/$jobname" 2>&1 || true)
  printf '%s\n' "$logs" | grep '^backup-cronjob:' || true
  if [ "$(grep -c '^backup-cronjob: verify ok$' <<<"$logs")" -eq 1 ]; then pass "log has verify ok"; else bad "log has verify ok"; fi
  if [ "$(grep -c '^backup-cronjob: done$' <<<"$logs")" -eq 1 ]; then pass "log has done"; else bad "log has done"; fi
  last=$(kubectl -n "$NS" get cronjob "$CJ" -o jsonpath='{.status.lastScheduleTime}')
  if [[ "$last" > "$start" ]]; then pass "lastScheduleTime moved after the start ($last)"; else bad "lastScheduleTime moved after the start ($last)"; fi
else
  bad "the controller created a Job from the CronJob within 6 minutes"
fi

after=$(count_backups)
echo "backups after: $after"
if [ "$after" -eq $((before + 1)) ]; then pass "the repository holds exactly one more backup"; else bad "the repository holds exactly one more backup (before $before, after $after)"; fi

exit "$fail"
