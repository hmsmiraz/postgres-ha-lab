#!/usr/bin/env bash
# REP-4 (Prometheus clause): replication lag in bytes and seconds is visible in Prometheus.
# Live: pauses WAL replay on the async replica for a short time, then resumes it. Prints numbers only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
source tests/lib/probe.sh

fails=0
ok() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fails=1; }

prom() {
  kubectl -n "$NS" exec pg-ha-0 -c postgres -- python3 -c 'import sys,urllib.request as u,urllib.parse as p;print(u.urlopen("http://prometheus.pg-ha.svc.cluster.local:9090/api/v1/query?query="+p.quote(sys.argv[1]),timeout=8).read().decode())' "$1" 2>/dev/null || true
}
val() { local o; o=$(prom "$1" | jq -r '.data.result[0].value[1] // "none"' 2>/dev/null || true); echo "${o:-none}"; }
count() { local o; o=$(prom "$1" | jq -r '.data.result | length' 2>/dev/null || true); echo "${o:-0}"; }
positive() { awk -v v="$1" 'BEGIN{exit !(v ~ /^[0-9.eE+-]+$/ && v+0 > 0)}'; }
zero() { awk -v v="$1" 'BEGIN{exit !(v ~ /^[0-9.eE+-]+$/ && v+0 == 0)}'; }

echo "date_utc: $(date -u +%FT%TZ)"
now_min=$((10#$(date -u +%H) * 60 + 10#$(date -u +%M)))
if [ "$now_min" -ge 110 ] && [ "$now_min" -le 135 ]; then echo "too close to 02:00 UTC, refusing to run"; exit 2; fi
wait_healthy 60 || { echo "cluster not healthy, refusing"; exit 2; }

state=$(cluster_json)
target=$(jq -r '[.[] | select(.Role == "Replica" and .State == "streaming")][0].Member // empty' <<<"$state")
other=$(jq -r '[.[] | select(.Role == "Sync Standby")][0].Member // empty' <<<"$state")
leader=$(current_leader)
if [ -z "$target" ] || [ -z "$other" ] || [ -z "$leader" ]; then echo "no async replica, sync standby or leader found, refusing"; exit 2; fi
echo "leader: $leader  async replica (paused): $target  sync standby (control): $other"

psql_on() { kubectl -n "$NS" exec "$1" -c postgres -- psql -U postgres -Atqc "$2"; }
holder=""
resume() { if [ -n "$holder" ]; then kill "$holder" 2>/dev/null; fi; holder=""; psql_on "$target" "select pg_wal_replay_resume()" >/dev/null 2>&1 || true; }
trap resume EXIT

bq() { echo "pg_stat_replication_pg_wal_lsn_diff{application_name=\"$1\"}"; }
sq() { echo "pg_replication_lag_seconds{instance=~\"$1.*\"}"; }

if [ "$(val 'pg_stat_replication_pg_wal_lsn_diff{application_name="no-such-pod"}')" = none ]; then ok "control: an absent series reads as none"; else bad "control: an absent series reads as none"; fi
if [ "$(count pg_stat_replication_pg_wal_lsn_diff)" = 2 ]; then ok "bytes lag has 2 series (one per replica)"; else bad "bytes lag has 2 series (one per replica)"; fi
if [ "$(count pg_replication_lag_seconds)" = 3 ]; then ok "seconds lag has 3 series (one per pod)"; else bad "seconds lag has 3 series (one per pod)"; fi
b0=$(val "$(bq "$target")")
if zero "$b0"; then ok "baseline: $target bytes lag is 0"; else bad "baseline: $target bytes lag is 0 (is $b0)"; fi

psql_on "$target" "select pg_wal_replay_pause()" >/dev/null 2>&1
( while true; do psql_on "$target" "select pg_wal_replay_pause()" >/dev/null 2>&1; psql_on "$leader" "select pg_logical_emit_message(true, 'obs_lag', repeat('x', 8000))" >/dev/null 2>&1 || true; sleep 1; done ) &
holder=$!
seen=no
for _ in $(seq 1 10); do
  if [ "$(psql_on "$target" "select pg_is_wal_replay_paused()" 2>/dev/null)" = t ]; then seen=yes; break; fi
  sleep 1
done
if [ "$seen" = yes ]; then ok "replay is paused on $target (seen within 10 s)"; else bad "replay is paused on $target (not seen within 10 s)"; fi

bl=none; sl=none
for _ in $(seq 1 16); do
  bl=$(val "$(bq "$target")"); sl=$(val "$(sq "$target")")
  if positive "$bl" && positive "$sl"; then break; fi
  sleep 5
done
echo "during pause: $target bytes lag $bl, seconds lag $sl"
if positive "$bl"; then ok "bytes lag of $target rises above 0 while replay is paused"; else bad "bytes lag of $target rises above 0 while replay is paused"; fi
if positive "$sl"; then ok "seconds lag of $target rises above 0 while replay is paused"; else bad "seconds lag of $target rises above 0 while replay is paused"; fi
bo=$(val "$(bq "$other")")
if zero "$bo"; then ok "control: $other bytes lag stays 0"; else bad "control: $other bytes lag stays 0 (is $bo)"; fi

resume
br=none
for _ in $(seq 1 18); do
  br=$(val "$(bq "$target")")
  if zero "$br"; then break; fi
  sleep 5
done
echo "after resume: $target bytes lag $br"
if zero "$br"; then ok "bytes lag of $target returns to 0 after resume"; else bad "bytes lag of $target returns to 0 after resume"; fi
if [ "$(psql_on "$target" "select pg_is_wal_replay_paused()" 2>/dev/null)" = f ]; then ok "replay is running again on $target"; else bad "replay is running again on $target"; fi
exit "$fails"
