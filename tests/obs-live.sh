#!/usr/bin/env bash
# OBS-1 (stage A, live, read only): the three deployments are available and Prometheus reports every target up.
# Queries run from inside pg-ha-0 against the in-cluster Services. Prints counts only, no secrets.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

NS=pg-ha
fail=0
pass() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }

fetch() { # url -> body on stdout, empty on error
  kubectl -n "$NS" exec pg-ha-0 -c postgres -- python3 -c 'import sys,urllib.request as u;print(u.urlopen(sys.argv[1],timeout=8).read().decode())' "$1" 2>/dev/null || true
}

echo "date_utc: $(date -u +%FT%TZ)"
for d in prometheus kube-state-metrics grafana; do
  a=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
  if [ "${a:-0}" = 1 ]; then pass "deployment $d is available"; else bad "deployment $d is available (available: ${a:-none})"; fi
done

ready=$(fetch http://prometheus.pg-ha.svc.cluster.local:9090/-/ready | grep -c 'Ready' || true)
if [ "${ready:-0}" -ge 1 ]; then pass "prometheus is ready"; else bad "prometheus is ready"; fi

targets=$(fetch 'http://prometheus.pg-ha.svc.cluster.local:9090/api/v1/targets?state=active')
for pair in patroni:3 postgres-exporter:3 kube-state-metrics:1 prometheus:1; do
  job=${pair%%:*}; want=${pair##*:}
  n=$(printf '%s' "$targets" | jq --arg j "$job" '[.data.activeTargets[]? | select(.labels.job == $j and .health == "up")] | length' 2>/dev/null || true)
  if [ "${n:-0}" = "$want" ]; then pass "job $job has $want targets up"; else bad "job $job has $want targets up (found ${n:-0})"; fi
done

health=$(fetch http://grafana.pg-ha.svc.cluster.local:3000/api/health | jq -r '.database' 2>/dev/null || true)
if [ "$health" = ok ]; then pass "grafana health reports database ok"; else bad "grafana health reports database ok"; fi

n=$(printf '{"x":1}' | jq '[.data.activeTargets[]? ] | length' 2>/dev/null || true)
if [ "${n:-0}" = 0 ]; then pass "control: the target counter returns 0 for input without targets"; else bad "control: the target counter returns 0 for input without targets"; fi
exit "$fail"
