#!/usr/bin/env bash
# OBS-2 (live, read only): Prometheus has loaded the 5 alert rules, all healthy, none firing on a healthy cluster.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
NS=pg-ha
fail=0
pass() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }

rules=$(kubectl -n "$NS" exec pg-ha-0 -c postgres -- python3 -c 'import urllib.request as u;print(u.urlopen("http://prometheus.pg-ha.svc.cluster.local:9090/api/v1/rules",timeout=8).read().decode())' 2>/dev/null || true)
q() { printf '%s' "$rules" | jq -r "$1" 2>/dev/null || true; }

echo "date_utc: $(date -u +%FT%TZ)"
n=$(q '[.data.groups[]? | select(.name=="pg-ha") | .rules[]?] | length')
if [ "${n:-0}" = 5 ]; then pass "group pg-ha has 5 rules"; else bad "group pg-ha has 5 rules (found ${n:-0})"; fi
for a in NoPrimary ReplicationLag SlotRetention WalArchiveFailure BackupTooOld; do
  c=$(q "[.data.groups[]?.rules[]? | select(.name==\"$a\")] | length")
  if [ "${c:-0}" = 1 ]; then pass "alert $a is loaded"; else bad "alert $a is loaded"; fi
done
h=$(q '[.data.groups[]?.rules[]? | select(.health=="ok")] | length')
if [ "${h:-0}" = 5 ]; then pass "all 5 rules have health ok"; else bad "all 5 rules have health ok (found ${h:-0})"; fi
f2=$(q '[.data.groups[]?.rules[]? | select(.state=="firing")] | length')
if [ "$rules" != "" ] && [ "${f2:-x}" = 0 ]; then pass "no alert is firing on a healthy cluster"; else bad "no alert is firing on a healthy cluster (firing: ${f2:-unknown})"; fi
z=$(printf '{"data":{"groups":[]}}' | jq '[.data.groups[]?.rules[]? | select(.name=="NoPrimary")] | length' 2>/dev/null || true)
if [ "${z:-x}" = 0 ]; then pass "control: an absent rule counts 0"; else bad "control: an absent rule counts 0"; fi
exit "$fail"
