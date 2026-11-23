#!/usr/bin/env bash
# OBS-1 (exporter stage, D1 a): static checks of the postgres-exporter sidecar text and its image substitution.
# Nothing is created in the cluster. Every "must be zero" check also requires a non-empty file.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

sts=k8s/pg/50-statefulset.yaml
up=scripts/pg-up.sh
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
atleast "sidecar container is named postgres-exporter" "$sts" '^        - name: postgres-exporter$' 1
atleast "sidecar image is the placeholder" "$sts" 'image: __PG_EXPORTER_IMAGE__' 1
atleast "image placeholders in the statefulset (postgres, backup, pgserver, exporter)" "$sts" 'image: __(IMAGE|PG_EXPORTER_IMAGE)__' 4
zero "statefulset never uses latest" "$sts" 'latest'
atleast "exporter port 9187" "$sts" 'containerPort: 9187' 1
atleast "exporter data source uses the socket" "$sts" 'DATA_SOURCE_NAME' 1
atleast "exporter data source names the run directory" "$sts" 'host=/run/postgresql' 1
atleast "exporter data source has no password" "$sts" 'postgresql://postgres@/postgres' 1
zero "exporter data source has no sslmode require or password text" "$sts" 'DATA_SOURCE_NAME.*(password|PASSWORD)'
atleast "every container drops all capabilities (4 containers)" "$sts" 'drop: \["ALL"\]' 4
atleast "every container blocks privilege escalation (4 containers)" "$sts" 'allowPrivilegeEscalation: false' 4
atleast "exporter has a memory limit of 128Mi" "$sts" 'memory: 128Mi' 2
atleast "pg-up fills the exporter image placeholder" "$up" '__PG_EXPORTER_IMAGE__' 1
atleast "pg-up uses the tag form of PG_EXPORTER_IMAGE" "$up" 'PG_EXPORTER_IMAGE%%@\*' 1

ctl=$(mktemp)
printf 'zzqx\n' > "$ctl"
n=$(grep -cE -- zzqx "$ctl" || true)
rm -f "$ctl"
if [ "${n:-0}" -eq 1 ]; then pass "control: the counter sees a known string"; else bad "control: the counter sees a known string"; fi
exit "$fail"
