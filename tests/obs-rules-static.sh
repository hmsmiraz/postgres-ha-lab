#!/usr/bin/env bash
# OBS-2 (static): alert rules in k8s/obs/25-rules.yaml, loaded by Prometheus through 20-prometheus.yaml.
# Nothing is created in the cluster. promtool runs from the pinned image without network.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
source versions.env

r=k8s/obs/25-rules.yaml
p=k8s/obs/20-prometheus.yaml
fail=0
pass() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
cnt() { local n; n=$(grep -cE -- "$2" "$1" 2>/dev/null || true); echo "${n:-0}"; }
atleast() { local n; n=$(cnt "$2" "$3"); if [ "$n" -ge "$4" ]; then pass "$1 ($n)"; else bad "$1 (found $n, need $4)"; fi; }

echo "date_utc: $(date -u +%FT%TZ)"
if [ -s "$r" ]; then pass "$r exists and is not empty"; else bad "$r exists and is not empty"; fi
atleast "rules ConfigMap is named prometheus-rules" "$r" '^  name: prometheus-rules$' 1
for a in NoPrimary ReplicationLag SlotRetention WalArchiveFailure BackupTooOld; do
  atleast "alert $a is defined" "$r" "alert: $a\$" 1
done
atleast "every alert has a for: duration" "$r" '^ +for: ' 5
atleast "prometheus config loads the rule files" "$p" 'rule_files:' 1
atleast "prometheus mounts the rules" "$p" 'mountPath: /etc/prometheus/rules' 1
atleast "prometheus has the rules volume" "$p" 'name: prometheus-rules' 1

ok=0
if [ -s "$r" ]; then
  t=$(mktemp -d); chmod 755 "$t"
  python3 -c 'import yaml,sys
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind")=="ConfigMap":
        open(sys.argv[2]+"/rules.yml","w").write(list(d["data"].values())[0])' "$r" "$t" 2>/dev/null
  img="${PROMETHEUS_IMAGE%%@*}"
  chmod 644 "$t/rules.yml" 2>/dev/null
  if [ -s "$t/rules.yml" ] && pt=$(docker run --rm --network none -v "$t:/r:ro" --entrypoint /bin/promtool "$img" check rules /r/rules.yml 2>&1); then ok=1; else echo "promtool said: $pt" | head -n 3; fi
  rm -rf "$t"
fi
if [ "$ok" = 1 ]; then pass "promtool check rules is clean"; else bad "promtool check rules is clean"; fi

n=$(grep -A4 'alert: ReplicationLag$' "$r" | grep -c 'for: 15s' || true)
if [ "${n:-0}" -ge 1 ]; then pass "ReplicationLag has for 15s"; else bad "ReplicationLag has for 15s"; fi
ctl=$(mktemp); printf 'zzqx\n' > "$ctl"
n=$(grep -cE -- zzqx "$ctl" || true); rm -f "$ctl"
if [ "${n:-0}" -eq 1 ]; then pass "control: the counter sees a known string"; else bad "control: the counter sees a known string"; fi
exit "$fail"
