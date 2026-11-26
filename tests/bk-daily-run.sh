#!/usr/bin/env bash
# Verify a retained Job from the configured daily schedule by its controller UID
# and scheduled timestamp. Temporary schedule tests use different timestamps.
set -euo pipefail
# An optional UTC date requires the backup container to start within the scheduled minute.
expected_date=${1:-}
if [[ $# -gt 1 || (-n "$expected_date" && ! "$expected_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$) ]]; then
  echo "Usage: $0 [YYYY-MM-DD]" >&2
  exit 2
fi
ns=pg-ha
name=pgbackrest-backup
cron=$(kubectl -n "$ns" get cronjob "$name" -o json)
jq -e '.spec.schedule == "0 2 * * *" and .spec.timeZone == "Etc/UTC" and .spec.suspend != true' <<<"$cron" >/dev/null
uid=$(jq -er '.metadata.uid' <<<"$cron")
jobs=$(kubectl -n "$ns" get jobs -o json)
job=$(jq -r --arg uid "$uid" --arg date "$expected_date" '[.items[] |
  select(any(.metadata.ownerReferences[]?; .controller == true and .uid == $uid)) |
  select(.metadata.annotations["batch.kubernetes.io/cronjob-scheduled-timestamp"] // "" | endswith("T02:00:00Z")) |
  select($date == "" or .metadata.annotations["batch.kubernetes.io/cronjob-scheduled-timestamp"] == ($date + "T02:00:00Z")) |
  select(.status.succeeded == 1)] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty' <<<"$jobs")
if [ -z "$job" ]; then
  echo "No retained successful Job scheduled for 02:00 UTC."
  exit 1
fi
logs=$(kubectl -n "$ns" logs "job/$job")
grep -Fx 'backup-cronjob: verify ok' <<<"$logs" >/dev/null
grep -Fx 'backup-cronjob: done' <<<"$logs" >/dev/null
echo "PASS $job was scheduled for 02:00 UTC, completed, and verified its backup."
jq -r --arg job "$job" '.items[] | select(.metadata.name == $job) |
  .metadata.annotations["batch.kubernetes.io/cronjob-scheduled-timestamp"] as $scheduled |
  "Scheduled \($scheduled), created \(.metadata.creationTimestamp), completed \(.status.completionTime), controller delay \((.metadata.creationTimestamp | fromdateiso8601) - ($scheduled | fromdateiso8601)) seconds."' <<<"$jobs"
if [[ -n "$expected_date" ]]; then
  job_uid=$(jq -er --arg job "$job" '.items[] | select(.metadata.name==$job) | .metadata.uid' <<<"$jobs")
  pods=$(kubectl -n "$ns" get pods -l "batch.kubernetes.io/controller-uid=$job_uid" -o json)
  started=$(jq -er '[.items[] | select(.status.phase=="Succeeded") |
    .status.containerStatuses[] | select(.state.terminated.exitCode==0) |
    .state.terminated.startedAt] | min // empty' <<<"$pods")
  scheduled="${expected_date}T02:00:00Z"
  delay=$(( $(date -u -d "$started" +%s) - $(date -u -d "$scheduled" +%s) ))
  echo "Backup container started $started ($delay seconds after schedule)."
  if (( delay < 0 || delay >= 60 )); then
    echo "FAIL backup started outside the scheduled minute."
    exit 1
  fi
  echo "PASS backup started during the scheduled 02:00 UTC minute."
fi
