#!/usr/bin/env bash
# BK-3: retention is enforced by pgBackRest settings. PGBACKREST_REPO1_RETENTION_FULL=2 (type count, the default) is set in the
# ConfigMap pgbackrest-env, which the backup CronJob reads. Checked here: the setting, that the CronJob does not override it,
# that no job log carries the warning about the missing setting, then the effect: full backups are made until 2 exist, exactly 2
# exist before the final job, and after one more full backup exactly 2 remain, the oldest full backup and the incrementals that
# depended on it are gone, the newer full backup stays, and the oldest archived WAL moves up but not past the start WAL of the
# oldest retained full backup. The job logs hold no secret value.
# Left behind on purpose: 2 full backups (RS-1 needs one).
# Not covered: time-based retention, differential backups, expiry of a backup that is in use by a restore, a backup during
# an expire run. Leak scans use grep -c, never "producer | grep -q".
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source versions.env
# shellcheck source=/dev/null
source tests/lib/probe.sh

CJ=pgbackrest-backup
k() { kubectl -n "$NS" "$@"; }

umask 077
work=$(mktemp -d)
# shellcheck disable=SC2329
cleanup() {
  rm -rf "$work"
  kubectl -n "$NS" delete job -l app=bk-retention-test --ignore-not-found --wait=false >/dev/null 2>&1 || true
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
full_labels() { jq -r '[.[0].backup[]? | select(.type == "full") | .label] | sort | join(",")' <<<"$1"; }

make_job() {
  local name=$1 kv key val filter
  shift
  # shellcheck disable=SC2016
  filter='{apiVersion:"batch/v1",kind:"Job",metadata:{name:$name,namespace:"pg-ha",labels:{app:"bk-retention-test"}},spec:.spec.jobTemplate.spec}'
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
  RESULT=$(wait_job "$name" 600)
  LOG=$(k logs "job/$name" --all-containers 2>&1 || true)
  printf '%s\n' "$LOG" >>"$work/logs"
  echo "INFO: $name result=$RESULT, log lines=$(grep -c '' <<<"$LOG" || true)"
}

echo "date: $(date -u +%FT%TZ)"
k get sts pg-ha >/dev/null 2>&1 || fail "StatefulSet pg-ha is missing"
wait_healthy 120 || fail "Patroni does not report 1 leader and 2 streaming replicas"
pass "cluster healthy: 1 leader and 2 streaming replicas"

cm=$(k get configmap pgbackrest-env -o json 2>/dev/null || true)
[ -n "$cm" ] || fail "ConfigMap pgbackrest-env does not exist"
rf=$(jq -r '.data.PGBACKREST_REPO1_RETENTION_FULL // empty' <<<"$cm")
[ -n "$rf" ] || fail "PGBACKREST_REPO1_RETENTION_FULL is not set in the ConfigMap pgbackrest-env"
[ "$rf" = 2 ] || fail "PGBACKREST_REPO1_RETENTION_FULL is $rf, expected 2"
rt=$(jq -r '.data.PGBACKREST_REPO1_RETENTION_FULL_TYPE // "count"' <<<"$cm")
[ "$rt" = count ] || fail "the retention type is $rt, expected count"
pass "retention-full is 2 with type count in pgbackrest-env"

cj=$(k get cronjob "$CJ" -o json 2>/dev/null || true)
[ -n "$cj" ] || fail "CronJob $CJ does not exist"
n=$(jq '[.spec.jobTemplate.spec.template.spec.containers[0].envFrom[]? | select(.configMapRef.name == "pgbackrest-env")] | length' <<<"$cj")
[ "$n" = 1 ] || fail "the CronJob does not read pgbackrest-env"
n=$(jq '[.spec.jobTemplate.spec.template.spec.containers[0].env[]? | select(.name | startswith("PGBACKREST_REPO1_RETENTION"))] | length' <<<"$cj")
[ "$n" = 0 ] || fail "the CronJob overrides a retention variable in its own env"
pass "the CronJob reads pgbackrest-env and does not override retention"

warn="option 'repo1-retention-full' is not set"
[ "$(grep -F -c "$warn" <<<"WARN: $warn for 'repo1-retention-full-type=count'" || true)" -eq 1 ] || fail "control: the warning matcher did not fire on planted text"
sk=$(k get secret objstore-credentials -o json | jq -r '.data["secret-access-key"] // empty' | base64 -d)
kl=$(k get secret pgbackrest-tls-client -o json | jq -r '.data["tls.key"] // empty' | base64 -d | sed -n 2p)
[ -n "$sk" ] || fail "the secret access key could not be read"
[ -n "$kl" ] || fail "no key line could be read for the leak control"
printf '%s\n%s\n' "$sk" "$kl" >"$work/pat"
[ "$(grep -F -c -f "$work/pat" <<<"control line with $sk inside" || true)" -eq 1 ] || fail "control: the scanner did not fire on a planted secret"
[ "$(grep -F -c -f "$work/pat" <<<"control line with $kl inside" || true)" -eq 1 ] || fail "control: the scanner did not fire on a planted key line"
pass "controls: the warning matcher and the leak scanner fire on planted input"

k delete job -l app=bk-retention-test --ignore-not-found --wait=true >/dev/null
info0=$(info_json) || fail "cannot read pgbackrest info"
echo "INFO: baseline full=$(count_type "$info0" full) incr=$(count_type "$info0" incr)"
guard=0
nf=$(count_type "$info0" full)
while [ "$nf" -lt 2 ]; do
  guard=$((guard + 1))
  [ "$guard" -le 3 ] || fail "could not reach 2 full backups in 3 jobs"
  run_job "bk-retention-test-pre-$guard" BACKUP_FULL_INTERVAL_SECONDS=0
  [ "$RESULT" = complete ] || { printf '%s\n' "$LOG" | tail -n 8; fail "preparation job $guard ended with $RESULT"; }
  info0=$(info_json) || fail "cannot read pgbackrest info"
  nf=$(count_type "$info0" full)
done

info1=$(info_json) || fail "cannot read pgbackrest info before the final job"
nf1=$(count_type "$info1" full)
[ "$nf1" = 2 ] || fail "expected exactly 2 full backups before the final job, found $nf1 (retention is not capping the count)"
oldest=$(jq -r '[.[0].backup[] | select(.type == "full") | .label] | sort | .[0]' <<<"$info1")
newest=$(jq -r '[.[0].backup[] | select(.type == "full") | .label] | sort | .[-1]' <<<"$info1")
{ [ -n "$oldest" ] && [ "$oldest" != null ] && [ -n "$newest" ] && [ "$newest" != null ] && [ "$oldest" != "$newest" ]; } || fail "could not name the oldest and the newest full backup"
dep=$(jq --arg o "$oldest" '[.[0].backup[] | select(.type != "full") | select(.label | startswith($o + "_"))] | length' <<<"$info1")
nb1=$(jq '.[0].backup | length' <<<"$info1")
amin1=$(jq -r '[.[0].archive[].min] | sort | .[0]' <<<"$info1")
keep=$(jq -r --arg l "$newest" '.[0].backup[] | select(.label == $l) | .archive.start' <<<"$info1")
{ [ -n "$amin1" ] && [ "$amin1" != null ] && [ -n "$keep" ] && [ "$keep" != null ]; } || fail "could not read the archive range or the start WAL of the kept full backup"
echo "INFO: before the final job: full=$nf1 oldest=$oldest newest=$newest incrementals depending on the oldest=$dep total=$nb1 archive min=$amin1 kept start=$keep"
pass "exactly 2 full backups exist before the final job"

run_job bk-retention-test-final BACKUP_FULL_INTERVAL_SECONDS=0
[ "$RESULT" = complete ] || { printf '%s\n' "$LOG" | tail -n 8; fail "the final job ended with $RESULT"; }
info2=$(info_json) || fail "cannot read pgbackrest info after the final job"
nf2=$(count_type "$info2" full)
[ "$nf2" = 2 ] || fail "expected exactly 2 full backups after the final job, found $nf2"
gone=$(jq --arg o "$oldest" '[.[0].backup[] | select(.label == $o)] | length' <<<"$info2")
[ "$gone" = 0 ] || fail "the oldest full backup $oldest was not expired"
kept=$(jq --arg l "$newest" '[.[0].backup[] | select(.label == $l)] | length' <<<"$info2")
[ "$kept" = 1 ] || fail "the newer full backup $newest is gone"
lab2=$(full_labels "$info2")
newfull=$(jq -r --arg l "$newest" '[.[0].backup[] | select(.type == "full") | .label] | sort | .[-1] | select(. != $l)' <<<"$info2")
[ -n "$newfull" ] || fail "no new full backup appeared (labels: $lab2)"
orph=$(jq --arg o "$oldest" '[.[0].backup[] | select(.label | startswith($o + "_"))] | length' <<<"$info2")
[ "$orph" = 0 ] || fail "$orph incremental backups of the expired full backup are still listed"
nb2=$(jq '.[0].backup | length' <<<"$info2")
[ "$nb2" = $((nb1 - dep)) ] || fail "the total went from $nb1 to $nb2, expected $((nb1 - dep))"
pass "the oldest full backup $oldest and its $dep incremental backups were expired, $newest stays, $newfull is new, total $nb1 to $nb2"

amin2=$(jq -r '[.[0].archive[].min] | sort | .[0]' <<<"$info2")
[ -n "$amin2" ] && [ "$amin2" != null ] || fail "could not read the archive range after the final job"
[[ "$amin2" > "$amin1" ]] || fail "the oldest archived WAL did not move up (before $amin1, after $amin2)"
{ [[ "$amin2" < "$keep" ]] || [ "$amin2" = "$keep" ]; } || fail "the oldest archived WAL $amin2 is newer than the start WAL $keep of the kept full backup"
pass "the oldest archived WAL moved up from $amin1 to $amin2 and does not pass the start WAL $keep of the oldest kept full backup"

logs=$(cat "$work/logs")
[ -n "$logs" ] || fail "the collected job logs are empty, so the scans would prove nothing"
[ "$(grep -F -c "$warn" <<<"$logs" || true)" -eq 0 ] || fail "a job log still carries the warning about the missing retention setting"
[ "$(grep -F -c -f "$work/pat" <<<"$logs" || true)" -eq 0 ] || fail "a secret value or key line appears in a job log"
[ "$(grep -F -c 'PRIVATE KEY' <<<"$logs" || true)" -eq 0 ] || fail "a private key marker appears in a job log"
pass "no missing-retention warning, secret value, key line or private key marker in the job logs"
echo "ALL CHECKS PASSED"
