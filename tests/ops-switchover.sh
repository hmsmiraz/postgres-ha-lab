#!/usr/bin/env bash
# OPS-3: planned switchover to the sync standby with the write probe running. Live: it changes the cluster.
# Prints counts and measurements, no secrets.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
source tests/lib/probe.sh
fails=0
ok() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fails=1; }
LOG=$(mktemp)
trap 'kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true; rm -f "$LOG"' EXIT

echo "date_utc: $(date -u +%FT%TZ)"
now_min=$((10#$(date -u +%H) * 60 + 10#$(date -u +%M)))
if [ "$now_min" -ge 110 ] && [ "$now_min" -le 135 ]; then echo "too close to 02:00 UTC, refusing"; exit 2; fi
if [ "$(kubectl -n "$NS" get jobs -o json | jq '[.items[] | select(.status.active != null)] | length')" != 0 ]; then echo "a Job is active, refusing"; exit 2; fi
wait_healthy 60 || { echo "cluster not healthy, refusing"; exit 2; }

state=$(cluster_json)
old=$(jq -r '.[] | select(.Role=="Leader") | .Member' <<<"$state")
cand=$(jq -r '[.[] | select(.Role=="Sync Standby")][0].Member // empty' <<<"$state")
if [ -z "$old" ] || [ -z "$cand" ]; then echo "no leader or sync standby found, refusing"; exit 2; fi
tl0=$(jq -r '[.[].TL] | max' <<<"$state")
echo "leader: $old  candidate (sync standby): $cand  timeline before: $tl0"

start_probe
start_ms=$(now_ms)
kubectl -n "$NS" exec "$old" -c postgres -- patronictl -c /etc/patroni/patroni.yml switchover --leader "$old" --candidate "$cand" --force 2>&1 | tail -n 3 | cut -c1-160
if wait_healthy 300; then ok "cluster is back to 1 leader + 2 streaming replicas"; else bad "cluster is back to 1 leader + 2 streaming replicas within 5 minutes"; fi
sleep 10
kubectl -n "$NS" logs "$PROBE" > "$LOG"

new=$(current_leader)
tl1=$(cluster_json | jq -r '[.[].TL] | max')
echo "leader after: $new  timeline after: $tl1 (before $tl0)"
if [ "$new" = "$cand" ]; then ok "the sync standby $cand is the new leader"; else bad "the sync standby $cand is the new leader (leader is $new)"; fi
if [ "${tl1:-0}" -gt "${tl0:-0}" ]; then ok "timeline rose"; else bad "timeline rose"; fi
read -r oks errs max_gap _ < <(analyze_probe "$LOG" "$start_ms")
echo "acknowledged writes: $oks, failed attempts: $errs, largest gap between writes: ${max_gap} ms"
missing=$(acked_missing_verbose "$LOG")
echo "acknowledged writes missing from the table: $missing"
if [ "$missing" = 0 ]; then ok "no acknowledged write is missing"; else bad "no acknowledged write is missing ($missing)"; fi
if [ "$(writable_primaries)" = 1 ]; then ok "exactly one writable primary"; else bad "exactly one writable primary"; fi
echo "=== tests/sec-tls.sh ==="
bash tests/sec-tls.sh || fails=1
echo "=== tests/obs-exporter-live.sh ==="
bash tests/obs-exporter-live.sh || fails=1
exit "$fails"
