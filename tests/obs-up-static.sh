#!/usr/bin/env bash
# OBS-1 (Stage A): static checks for scripts/obs-up.sh and scripts/gen-grafana-secret.sh.
# Nothing is created in the cluster. Every "must be zero" check also requires its file to be non-empty.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

up=scripts/obs-up.sh
gen=scripts/gen-grafana-secret.sh
fail=0
pass() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }

cnt() { # file pattern
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

for x in "$up" "$gen"; do
  if [ -x "$x" ]; then pass "$x exists and is executable"; else bad "$x exists and is executable"; fi
done

atleast "obs-up has set -euo pipefail" "$up" '^set -euo pipefail$' 1
atleast "obs-up sources versions.env" "$up" 'source versions\.env' 1
atleast "obs-up uses the tag form of PROMETHEUS_IMAGE" "$up" 'PROMETHEUS_IMAGE%%@\*' 1
atleast "obs-up uses the tag form of KSM_IMAGE" "$up" 'KSM_IMAGE%%@\*' 1
atleast "obs-up uses the tag form of GRAFANA_IMAGE" "$up" 'GRAFANA_IMAGE%%@\*' 1
atleast "obs-up fills the three image placeholders" "$up" '__(PROMETHEUS|KSM|GRAFANA)_IMAGE__' 3
atleast "obs-up applies the four manifest files" "$up" '(10-rbac|20-prometheus|30-ksm|40-grafana)\.yaml' 4
atleast "obs-up waits for the three rollouts" "$up" 'rollout status deploy/(prometheus|kube-state-metrics|grafana)' 3
zero "obs-up never deletes anything" "$up" 'kubectl[^|]* delete'

l1=$(grep -nE 'gen-grafana-secret' "$up" 2>/dev/null | head -n 1 | cut -d: -f1 || true)
l2=$(grep -nE '40-grafana' "$up" 2>/dev/null | head -n 1 | cut -d: -f1 || true)
if [ -n "${l1:-}" ] && [ -n "${l2:-}" ] && [ "$l1" -lt "$l2" ]; then pass "obs-up creates the Secret before it applies 40-grafana.yaml"; else bad "obs-up creates the Secret before it applies 40-grafana.yaml"; fi

atleast "generator has set -euo pipefail" "$gen" '^set -euo pipefail$' 1
atleast "generator defaults to namespace pg-ha" "$gen" 'NS="\$\{NS:-pg-ha\}"' 1
atleast "generator writes the key admin-password" "$gen" 'admin-password' 1
atleast "generator draws the value from openssl rand" "$gen" 'openssl rand' 1
atleast "generator keeps an existing Secret" "$gen" 'already exists, keeping it' 1
atleast "generator names the Secret grafana-admin" "$gen" 'grafana-admin' 1
# shellcheck disable=SC2016
zero "generator never prints the value or traces" "$gen" '(echo|printf)[^|]*\$pw|set -x'

ctl=$(mktemp)
printf 'zzqx\n' > "$ctl"
n=$(grep -cE -- zzqx "$ctl" || true)
rm -f "$ctl"
if [ "${n:-0}" -eq 1 ]; then pass "control: the counter sees a known string"; else bad "control: the counter sees a known string"; fi

exit "$fail"
