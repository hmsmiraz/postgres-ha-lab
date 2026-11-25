#!/usr/bin/env bash
# Verify a retained Job from the configured daily schedule by its controller UID
# and scheduled timestamp. Temporary schedule tests use different timestamps.
set -euo pipefail
ns=pg-ha
name=pgbackrest-backup
cron=$(kubectl -n "$ns" get cronjob "$name" -o json)
jq -e '.spec.schedule == "0 2 * * *" and .spec.timeZone == "Etc/UTC" and .spec.suspend != true' <<<"$cron" >/dev/null
uid=$(jq -er '.metadata.uid' <<<"$cron")
jobs=$(kubectl -n "$ns" get jobs -o json)
job=$(jq -r --arg uid "$uid" '[.items[] |
  select(any(.metadata.ownerReferences[]?; .controller == true and .uid == $uid)) |
  select(.metadata.annotations["batch.kubernetes.io/cronjob-scheduled-timestamp"] // "" | endswith("T02:00:00Z")) |
  select(.status.succeeded == 1)] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty' <<<"$jobs")
if [ -z "$job" ]; then
  echo "No retained successful Job scheduled for 02:00 UTC."
  exit 1
fi
logs=$(kubectl -n "$ns" logs "job/$job")
grep -Fx 'backup-cronjob: verify ok' <<<"$logs" >/dev/null
grep -Fx 'backup-cronjob: done' <<<"$logs" >/dev/null
echo "PASS $job was scheduled for 02:00 UTC, completed, and verified its backup."
