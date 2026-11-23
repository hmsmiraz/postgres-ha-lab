#!/usr/bin/env bash
# OBS-3 (unit): promtool tests of k8s/obs/25-rules.yaml with synthetic series, no network, no cluster.
# A deliberately wrong expectation is the negative control and must fail.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
source versions.env
fail=0
pass() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
img="${PROMETHEUS_IMAGE%%@*}"
t=$(mktemp -d); chmod 755 "$t"
trap 'rm -rf "$t"' EXIT
echo "date_utc: $(date -u +%FT%TZ)"

python3 -c 'import yaml,sys
for d in yaml.safe_load_all(open("k8s/obs/25-rules.yaml")):
    if d and d.get("kind")=="ConfigMap": open(sys.argv[1]+"/rules.yml","w").write(list(d["data"].values())[0])' "$t"
cp tests/obs-rules-unit.yml "$t/unit.yml"
cat > "$t/control.yml" <<'CTL'
rule_files:
  - rules.yml
evaluation_interval: 15s
tests:
  - name: control, healthy series but NoPrimary expected to fire
    interval: 15s
    input_series:
      - series: 'patroni_primary{instance="a"}'
        values: '1x10'
    alert_rule_test:
      - eval_time: 2m
        alertname: NoPrimary
        exp_alerts:
          - exp_labels:
              severity: critical
CTL
chmod 644 "$t"/*.yml
if [ -s "$t/rules.yml" ]; then pass "rules extracted from the ConfigMap"; else bad "rules extracted from the ConfigMap"; fi

pt() { docker run --rm --network none -v "$t:/r:ro" --entrypoint /bin/promtool "$img" test rules "/r/$1" 2>&1; }
if out=$(pt unit.yml); then pass "all unit tests pass"; else bad "all unit tests pass"; echo "$out" | head -n 25; fi
if pt control.yml >/dev/null; then bad "negative control: a wrong expectation must fail"; else pass "negative control: a wrong expectation fails"; fi
exit "$fail"
