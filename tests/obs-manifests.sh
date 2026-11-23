#!/usr/bin/env bash
# OBS-1 (Stage A): static checks for k8s/obs/*.yaml. Nothing is created in the cluster and nothing is downloaded.
# Every "must be zero" check also requires its file to be non-empty, so a missing file cannot pass.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

d=k8s/obs
fail=0
pass() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }

cnt() { # file pattern -> number of matching lines (0 if the file is missing)
  local n
  n=$(grep -cE -- "$2" "$d/$1" 2>/dev/null || true)
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
  if [ -s "$d/$2" ] && [ "$n" -eq 0 ]; then pass "$1"; else bad "$1 (file empty or found $n)"; fi
}

echo "date_utc: $(date -u +%FT%TZ)"

for x in 10-rbac.yaml 20-prometheus.yaml 30-ksm.yaml 40-grafana.yaml; do
  if [ -s "$d/$x" ]; then pass "$x exists and is not empty"; else bad "$x exists and is not empty"; fi
done

atleast "rbac has a ClusterRole" 10-rbac.yaml '^kind: ClusterRole$' 1
zero "rbac has no write verb" 10-rbac.yaml '(create|delete|patch|update|\*)'

atleast "prometheus PVC is 2Gi" 20-prometheus.yaml 'storage: 2Gi' 1
atleast "prometheus retention is 7d" 20-prometheus.yaml 'retention.time=7d' 1
atleast "prometheus scrapes the three patroni pods on 8008" 20-prometheus.yaml 'pg-ha-[012]\.pg-ha-headless\.pg-ha\.svc\.cluster\.local:8008' 3
atleast "prometheus has a postgres-exporter job" 20-prometheus.yaml 'job_name: postgres-exporter' 1
atleast "prometheus scrapes the three exporters on 9187" 20-prometheus.yaml 'pg-ha-[012]\.pg-ha-headless\.pg-ha\.svc\.cluster\.local:9187' 3

atleast "prometheus image placeholder" 20-prometheus.yaml '__PROMETHEUS_IMAGE__' 1
atleast "ksm image placeholder" 30-ksm.yaml '__KSM_IMAGE__' 1
atleast "grafana image placeholder" 40-grafana.yaml '__GRAFANA_IMAGE__' 1

for x in 20-prometheus.yaml 30-ksm.yaml 40-grafana.yaml; do
  zero "$x never uses latest" "$x" 'latest'
  atleast "$x imagePullPolicy IfNotPresent" "$x" 'imagePullPolicy: IfNotPresent' 1
  atleast "$x runAsNonRoot" "$x" 'runAsNonRoot: true' 1
  atleast "$x no privilege escalation" "$x" 'allowPrivilegeEscalation: false' 1
  atleast "$x drops all capabilities" "$x" 'drop: \["ALL"\]' 1
  atleast "$x seccomp RuntimeDefault" "$x" 'type: RuntimeDefault' 1
done
atleast "prometheus runs as 65534" 20-prometheus.yaml 'runAsUser: 65534' 1
atleast "ksm runs as 65534" 30-ksm.yaml 'runAsUser: 65534' 1
atleast "grafana runs as 472" 40-grafana.yaml 'runAsUser: 472' 1

n=$(grep -A3 GF_SECURITY_ADMIN_PASSWORD "$d/40-grafana.yaml" 2>/dev/null | grep -c secretKeyRef || true)
if [ "${n:-0}" -ge 1 ]; then pass "grafana admin password comes from a secretKeyRef"; else bad "grafana admin password comes from a secretKeyRef"; fi

ctl=$(mktemp)
printf 'zzqx\n' > "$ctl"
n=$(grep -cE -- zzqx "$ctl" || true)
rm -f "$ctl"
if [ "${n:-0}" -eq 1 ]; then pass "control: the counter sees a known string"; else bad "control: the counter sees a known string"; fi

exit "$fail"
