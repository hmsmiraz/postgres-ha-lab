#!/usr/bin/env bash
# BK-2 (ADR-0002): one CronJob, pgbackrest-backup, runs scheduled backups through the pgserver endpoints. It makes a full
# backup when none exists or the last full is older than BACKUP_FULL_INTERVAL_SECONDS, and an incremental one otherwise.
# Checked here: the CronJob spec (Forbid, schedule, deadline, no ServiceAccount token, pinned image, three TLS pg hosts,
# only the expected Secrets), no secret value in the CronJob or any ConfigMap, then four Jobs built from the CronJob template:
# job 1 (full if no full exists, else incremental), job 2 (incremental), job 3 (interval 0, so full), job 4 (all CA paths
# broken, must fail and must not add a backup). Counts come from pgbackrest info. The job logs hold no secret value.
# Left behind on purpose: the backups, because RS-1 needs one (retention is BK-3).
# Not covered: that Forbid blocks an overlapping run (only the setting is checked), that the real schedule fires on time,
# and which pod a backup reads from. Leak scans use grep -c, never "producer | grep -q".
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source versions.env
# shellcheck source=/dev/null
source tests/lib/probe.sh

CJ=pgbackrest-backup
IMG="${IMAGE_NAME}:${IMAGE_TAG}"
k() { kubectl -n "$NS" "$@"; }

umask 077
work=$(mktemp -d)
# shellcheck disable=SC2329
cleanup() {
  rm -rf "$work"
  kubectl -n "$NS" delete job -l app=bk-schedule-test --ignore-not-found --wait=false >/dev/null 2>&1 || true
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

# make_job NAME [KEY=VALUE ...]: a Job from the CronJob's jobTemplate, with env overrides.
make_job() {
  local name=$1 kv key val filter
  shift
  # shellcheck disable=SC2016
  filter='{apiVersion:"batch/v1",kind:"Job",metadata:{name:$name,namespace:"pg-ha",labels:{app:"bk-schedule-test"}},spec:.spec.jobTemplate.spec}'
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
JOBWAIT=600
run_job() {
  local name=$1
  shift
  make_job "$name" "$@"
  RESULT=$(wait_job "$name" "$JOBWAIT")
  LOG=$(k logs "job/$name" --all-containers 2>&1 || true)
  printf '%s\n' "$LOG" >>"$work/logs"
  echo "INFO: $name result=$RESULT, log lines=$(grep -c '' <<<"$LOG" || true)"
}

echo "date: $(date -u +%FT%TZ)"
k get sts pg-ha >/dev/null 2>&1 || fail "StatefulSet pg-ha is missing"
wait_healthy 120 || fail "Patroni does not report 1 leader and 2 streaming replicas"
pass "cluster healthy: 1 leader and 2 streaming replicas"

cj=$(k get cronjob "$CJ" -o json 2>/dev/null || true)
[ -n "$cj" ] || fail "CronJob $CJ does not exist"
[ "$(jq -r '.spec.concurrencyPolicy' <<<"$cj")" = Forbid ] || fail "concurrencyPolicy must be Forbid"
sched=$(jq -r '.spec.schedule // empty' <<<"$cj")
[ -n "$sched" ] || fail "the CronJob has no schedule"
[ "$(awk '{print NF}' <<<"$sched")" = 5 ] || fail "the schedule does not have 5 fields"
[ "$(jq -r '.spec.suspend // false' <<<"$cj")" = false ] || fail "the CronJob is suspended"
[ "$(jq -r '.spec.jobTemplate.spec.backoffLimit' <<<"$cj")" = 0 ] || fail "backoffLimit must be 0"
d=$(jq -r '.spec.jobTemplate.spec.activeDeadlineSeconds // 0' <<<"$cj")
[ "$d" -gt 0 ] || fail "activeDeadlineSeconds must be set"
[ "$(jq -r '.spec.jobTemplate.spec.template.spec.restartPolicy' <<<"$cj")" = Never ] || fail "restartPolicy must be Never"
[ "$(jq -r '.spec.jobTemplate.spec.template.spec.containers[0].image' <<<"$cj")" = "$IMG" ] || fail "the image must be $IMG"
[ "$(jq -r '.spec.jobTemplate.spec.template.spec.automountServiceAccountToken' <<<"$cj")" = false ] || fail "automountServiceAccountToken must be false"
pass "CronJob spec: Forbid, 5-field schedule, not suspended, backoffLimit 0, deadline, Never, pinned image, no ServiceAccount token"

for i in 1 2 3; do
  h=$(jq -r --arg n "PGBACKREST_PG${i}_HOST" '.spec.jobTemplate.spec.template.spec.containers[0].env[]? | select(.name == $n) | .value' <<<"$cj")
  [ "$h" = "pg-ha-$((i - 1)).pg-ha-headless.$NS.svc.cluster.local" ] || fail "PGBACKREST_PG${i}_HOST is not the pod DNS name of pg-ha-$((i - 1))"
  t=$(jq -r --arg n "PGBACKREST_PG${i}_HOST_TYPE" '.spec.jobTemplate.spec.template.spec.containers[0].env[]? | select(.name == $n) | .value' <<<"$cj")
  [ "$t" = tls ] || fail "PGBACKREST_PG${i}_HOST_TYPE is not tls"
done
secrets=$(jq -r '[.spec.jobTemplate.spec.template.spec | ((.volumes[]? | .secret.secretName // empty), (.containers[0].env[]? | .valueFrom.secretKeyRef.name // empty))] | unique | join(",")' <<<"$cj")
[ "$secrets" = "objstore-credentials,objstore-tls,pgbackrest-tls-client" ] || fail "the CronJob references unexpected Secrets: $secrets"
pass "three TLS pg hosts with the pod DNS names; only the expected three Secrets are referenced"

sk=$(k get secret objstore-credentials -o json | jq -r '.data["secret-access-key"] // empty' | base64 -d)
kl=$(k get secret pgbackrest-tls-client -o json | jq -r '.data["tls.key"] // empty' | base64 -d | sed -n 2p)
[ -n "$sk" ] || fail "the secret access key could not be read"
[ -n "$kl" ] || fail "no key line could be read for the leak control"
printf '%s\n%s\n' "$sk" "$kl" >"$work/pat"
[ "$(grep -F -c -f "$work/pat" <<<"control line with $sk inside" || true)" -eq 1 ] || fail "leak control: the scanner did not fire on a planted secret"
[ "$(grep -F -c -f "$work/pat" <<<"control line with $kl inside" || true)" -eq 1 ] || fail "leak control: the scanner did not fire on a planted key line"
cms=$(k get configmap -o json)
[ -n "$cms" ] || fail "no ConfigMap listing, so the scan would prove nothing"
[ "$(grep -F -c -f "$work/pat" <<<"$cj" || true)" -eq 0 ] || fail "a secret value appears in the CronJob"
[ "$(grep -F -c -f "$work/pat" <<<"$cms" || true)" -eq 0 ] || fail "a secret value appears in a ConfigMap"
pass "no secret value in the CronJob or any ConfigMap (scanner fired on planted input)"

k delete job -l app=bk-schedule-test --ignore-not-found --wait=true >/dev/null
info0=$(info_json) || fail "cannot read pgbackrest info"
f0=$(count_type "$info0" full)
i0=$(count_type "$info0" incr)
echo "INFO: baseline full=$f0 incr=$i0"

run_job bk-schedule-test-1
[ "$RESULT" = complete ] || { printf '%s\n' "$LOG" | tail -n 8; fail "job 1 ended with $RESULT"; }
info1=$(info_json) || fail "cannot read pgbackrest info after job 1"
f1=$(count_type "$info1" full)
i1=$(count_type "$info1" incr)
if [ "$f0" = 0 ]; then
  exp1=full
  { [ "$f1" = $((f0 + 1)) ] && [ "$i1" = "$i0" ]; } || fail "job 1 should add exactly one full backup (full $f0 to $f1, incr $i0 to $i1)"
else
  exp1=incr
  { [ "$i1" = $((i0 + 1)) ] && [ "$f1" = "$f0" ]; } || fail "job 1 should add exactly one incremental backup (full $f0 to $f1, incr $i0 to $i1)"
fi
[ "$(grep -c "backup-cronjob: type=$exp1" <<<"$LOG" || true)" = 1 ] || fail "the job 1 log does not say type=$exp1 exactly once"
pass "job 1 added one $exp1 backup (full $f0 to $f1, incr $i0 to $i1) and logged type=$exp1"

run_job bk-schedule-test-2
[ "$RESULT" = complete ] || { printf '%s\n' "$LOG" | tail -n 8; fail "job 2 ended with $RESULT"; }
info2=$(info_json) || fail "cannot read pgbackrest info after job 2"
f2=$(count_type "$info2" full)
i2=$(count_type "$info2" incr)
{ [ "$i2" = $((i1 + 1)) ] && [ "$f2" = "$f1" ]; } || fail "job 2 should add exactly one incremental backup (full $f1 to $f2, incr $i1 to $i2)"
[ "$(grep -c 'backup-cronjob: type=incr' <<<"$LOG" || true)" = 1 ] || fail "the job 2 log does not say type=incr exactly once"
[ "$(grep -c 'backup-cronjob: type=full' <<<"$LOG" || true)" = 0 ] || fail "the job 2 log also says type=full"
pass "job 2 added one incremental backup (incr $i1 to $i2) and logged type=incr"

run_job bk-schedule-test-3 BACKUP_FULL_INTERVAL_SECONDS=0
[ "$RESULT" = complete ] || { printf '%s\n' "$LOG" | tail -n 8; fail "job 3 ended with $RESULT"; }
info3=$(info_json) || fail "cannot read pgbackrest info after job 3"
f3=$(count_type "$info3" full)
i3=$(count_type "$info3" incr)
{ [ "$f3" = $((f2 + 1)) ] && [ "$i3" = "$i2" ]; } || fail "job 3 should add exactly one full backup (full $f2 to $f3, incr $i2 to $i3)"
[ "$(grep -c 'backup-cronjob: type=full' <<<"$LOG" || true)" = 1 ] || fail "the job 3 log does not say type=full exactly once"
pass "control: with the interval at 0, job 3 added one full backup (full $f2 to $f3)"

JOBWAIT=300
run_job bk-schedule-test-4 PGBACKREST_PG1_HOST_CA_FILE=/nonexistent/ca.crt PGBACKREST_PG2_HOST_CA_FILE=/nonexistent/ca.crt PGBACKREST_PG3_HOST_CA_FILE=/nonexistent/ca.crt
if [ "$RESULT" != failed ]; then printf '%s\n' "$LOG" | tail -n 8; fail "negative control: job 4 with broken CA paths ended with $RESULT, expected failed"; fi
info4=$(info_json) || fail "cannot read pgbackrest info after job 4"
{ [ "$(count_type "$info4" full)" = "$f3" ] && [ "$(count_type "$info4" incr)" = "$i3" ]; } || fail "negative control: the failed job changed the backup counts"
[ -n "$LOG" ] || fail "negative control: the failed job printed nothing, so the control proves nothing"
pass "negative control: broken CA paths make the Job fail and add no backup"

logs=$(cat "$work/logs")
[ -n "$logs" ] || fail "the collected job logs are empty, so the scan would prove nothing"
[ "$(grep -F -c -f "$work/pat" <<<"$logs" || true)" -eq 0 ] || fail "a secret value or key line appears in a job log"
[ "$(grep -F -c 'PRIVATE KEY' <<<"$logs" || true)" -eq 0 ] || fail "a private key marker appears in a job log"
pass "no secret value, key line or private key marker in the four job logs"
echo "ALL CHECKS PASSED"
