#!/usr/bin/env bash
# OBS-1 (exporter stage, D1 a): every Patroni pod answers on 9187 from inside the pod with pg_up 1 and the
# archiver and replication-slot metrics. Read only. Prints counts, no metric values beyond pg_up.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

NS=pg-ha
fail=0
pass() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }

echo "date_utc: $(date -u +%FT%TZ)"
for pod in pg-ha-0 pg-ha-1 pg-ha-2; do
  body=$(kubectl -n "$NS" exec "$pod" -c postgres -- python3 -c 'import urllib.request as u;print(u.urlopen("http://127.0.0.1:9187/metrics",timeout=5).read().decode())' 2>/dev/null || true)
  lines=$(printf '%s' "$body" | grep -c . || true)
  if [ "${lines:-0}" -gt 0 ]; then pass "$pod answers on 9187 ($lines lines)"; else bad "$pod answers on 9187 (no answer)"; continue; fi
  if [ "$(printf '%s\n' "$body" | grep -c '^pg_up 1$' || true)" -eq 1 ]; then pass "$pod pg_up is 1"; else bad "$pod pg_up is 1"; fi
  if [ "$(printf '%s\n' "$body" | grep -c '^pg_stat_archiver_' || true)" -ge 1 ]; then pass "$pod has archiver metrics"; else bad "$pod has archiver metrics"; fi
  if [ "$(printf '%s\n' "$body" | grep -c '^pg_replication_slots_' || true)" -ge 1 ]; then pass "$pod has replication slot metrics"; else bad "$pod has replication slot metrics"; fi
done
exit "$fail"
