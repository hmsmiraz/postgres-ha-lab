#!/usr/bin/env bash
# OBS-1 (UI): static checks for scripts/obs-open.sh, k8s/obs/50-dashboards.yaml and the Grafana news setting.
# Nothing is created in the cluster. Every "must be zero" check also requires a non-empty file.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

open=scripts/obs-open.sh
dash=k8s/obs/50-dashboards.yaml
graf=k8s/obs/40-grafana.yaml
fail=0
pass() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
cnt() {
  local n
  n=$(grep -cE -- "$2" "$1" 2>/dev/null || true)
  echo "${n:-0}"
}
atleast() { # description file pattern minimum
  local n
  n=$(cnt "$2" "$3")
  if [ "$n" -ge "$4" ]; then pass "$1 ($n)"; else bad "$1 (found $n, need $4)"; fi
}
zero() { # description file pattern
  local n
  n=$(cnt "$2" "$3")
  if [ -s "$2" ] && [ "$n" -eq 0 ]; then pass "$1"; else bad "$1 (file empty or found $n)"; fi
}

echo "date_utc: $(date -u +%FT%TZ)"
if [ -x "$open" ]; then pass "$open exists and is executable"; else bad "$open exists and is executable"; fi
atleast "obs-open binds 127.0.0.1" "$open" '127\.0\.0\.1' 1
atleast "obs-open forwards prometheus 9090" "$open" 'svc/prometheus 9090:9090' 1
atleast "obs-open forwards grafana 3000" "$open" 'svc/grafana 3000:3000' 1
zero "obs-open never uses 0.0.0.0" "$open" '0\.0\.0\.0'

if [ -s "$dash" ]; then pass "$dash exists and is not empty"; else bad "$dash exists and is not empty"; fi
atleast "dashboards ConfigMap is named grafana-dashboards" "$dash" '^  name: grafana-dashboards$' 1
atleast "dashboards ConfigMap is in pg-ha" "$dash" '^  namespace: pg-ha$' 1
for m in patroni_primary pg_up pg_stat_archiver_failed_count pg_replication_slots kube_cronjob_status_last_schedule_time; do
  atleast "dashboard queries $m" "$dash" "$m" 1
done

n=0
if [ -s "$dash" ]; then
  n=$(python3 -c 'import yaml,json,sys
c=0
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind")=="ConfigMap":
        for v in d.get("data",{}).values():
            json.loads(v); c+=1
print(c)' "$dash" 2>/dev/null || echo 0)
fi
if [ "${n:-0}" -ge 1 ]; then pass "dashboard JSON parses ($n)"; else bad "dashboard JSON parses"; fi

atleast "grafana news feed is disabled" "$graf" 'GF_NEWS_NEWS_FEED_ENABLED' 1

ctl=$(mktemp)
printf 'zzqx\n' > "$ctl"
n=$(grep -cE -- zzqx "$ctl" || true)
rm -f "$ctl"
if [ "${n:-0}" -eq 1 ]; then pass "control: the counter sees a known string"; else bad "control: the counter sees a known string"; fi
exit "$fail"
