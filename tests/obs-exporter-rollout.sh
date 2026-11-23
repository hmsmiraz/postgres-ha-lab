#!/usr/bin/env bash
# OBS-1 (exporter stage): rolling update of the pg-ha StatefulSet that adds the postgres-exporter sidecar,
# with the write probe running. Live: it changes the cluster. Prints counts and measurements, no secrets.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
source tests/lib/probe.sh
# shellcheck source=/dev/null
source versions.env

fails=0
ok() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fails=1; }
LOG=$(mktemp)
trap 'kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true; rm -f "$LOG"' EXIT

echo "date_utc: $(date -u +%FT%TZ)"
now_min=$((10#$(date -u +%H) * 60 + 10#$(date -u +%M)))
if [ "$now_min" -ge 110 ] && [ "$now_min" -le 135 ]; then echo "too close to 02:00 UTC, refusing to run"; exit 2; fi
if [ "$(grep -c 'name: postgres-exporter' k8s/pg/50-statefulset.yaml)" -ne 1 ]; then echo "sidecar not in the repo file, refusing"; exit 2; fi
wait_healthy 60 || { echo "cluster not healthy, refusing"; exit 2; }

tl_before=$(cluster_json | jq -r '[.[].TL] | max')
echo "timeline before: $tl_before"
start_probe
start_ms=$(now_ms)

IMG="${IMAGE_NAME}:${IMAGE_TAG}"
sed -e "s|__IMAGE__|${IMG}|g" -e "s|__PG_EXPORTER_IMAGE__|${PG_EXPORTER_IMAGE%%@*}|g" k8s/pg/50-statefulset.yaml | kubectl apply -f - >/dev/null
if kubectl -n "$NS" rollout status sts/pg-ha --timeout=900s >/dev/null 2>&1; then ok "rollout completed"; else bad "rollout completed within 15 minutes"; fi
if wait_healthy 300; then ok "cluster is back to 1 leader + 2 streaming replicas"; else bad "cluster is back to 1 leader + 2 streaming replicas"; fi
sleep 10
kubectl -n "$NS" logs "$PROBE" > "$LOG"

tl_after=$(cluster_json | jq -r '[.[].TL] | max')
echo "timeline after: $tl_after (before $tl_before)"
echo "leader after: $(current_leader)"
read -r oks errs max_gap _ < <(analyze_probe "$LOG" "$start_ms")
echo "acknowledged writes: $oks, failed attempts: $errs, largest gap between writes: ${max_gap} ms"
missing=$(acked_missing_verbose "$LOG")
echo "acknowledged writes missing from the table: $missing"
if [ "$missing" = 0 ]; then ok "no acknowledged write is missing"; else bad "no acknowledged write is missing ($missing)"; fi
echo "writable primaries now: $(writable_primaries)"
if [ "$(writable_primaries)" = 1 ]; then ok "exactly one writable primary"; else bad "exactly one writable primary"; fi
echo "archiver failed_count on the leader: $(kubectl -n "$NS" exec "$(current_leader)" -c postgres -- psql -U postgres -Atc 'select failed_count from pg_stat_archiver' 2>/dev/null)"
echo "restarts per container (pod/container/restarts):"
kubectl -n "$NS" get pods -l application=pg-ha -o json | jq -r '.items[] | .metadata.name as $p | .status.containerStatuses[] | "\($p) \(.name) \(.restartCount)"'
echo "=== live exporter test ==="
bash tests/obs-exporter-live.sh || fails=1
exit "$fails"
