#!/usr/bin/env bash
# SEC-6: trivy scan of ONE image per run. Usage: tests/sec-scan.sh N   (N = 1..8). Prints counts only, no CVE text.
# Order: 1 postgres-exporter, 2 kube-state-metrics, 3 nginx, 4 Garage, 5 Prometheus, 6 pg-ha, 7 postgres base, 8 Grafana.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
source versions.env
n=${1:-}
case "$n" in
  1) img=${PG_EXPORTER_IMAGE%%@*} ;;
  2) img=${KSM_IMAGE%%@*} ;;
  3) img=$OBJSTORE_PROXY_RUNTIME_IMAGE ;;
  4) img=${OBJSTORE_IMAGE%%@*} ;;
  5) img=${PROMETHEUS_IMAGE%%@*} ;;
  6) img="${IMAGE_NAME}:${IMAGE_TAG}" ;;
  7) img=${POSTGRES_BASE_IMAGE%%@*} ;;
  8) img=${GRAFANA_IMAGE%%@*} ;;
  *) echo "usage: $0 N (1..8)"; exit 2 ;;
esac
cache=$HOME/.cache/trivy-sec6; mkdir -p "$cache"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
echo "date_utc: $(date -u +%FT%TZ)  image $n: $img"
docker image inspect "$img" >/dev/null 2>&1 || { echo "FAIL  image $n is not on the host"; exit 1; }
docker save "$img" -o "$t/i.tar" 2>/dev/null || { echo "FAIL  docker save of image $n"; exit 1; }
if trivy image --cache-dir "$cache" --input "$t/i.tar" --scanners vuln --quiet --format json --output "$t/o.json" 2>"$t/err.txt" && [ -s "$t/o.json" ]; then
  tg=$(jq '[.Results[]?] | length' "$t/o.json")
  s=$(jq -r '[.Results[]?.Vulnerabilities[]? | .Severity] as $s | ["CRITICAL","HIGH","MEDIUM","LOW","UNKNOWN"] | map(. as $k | "\($k)=\([$s[] | select(. == $k)] | length)") | join(" ")' "$t/o.json")
  if [ "${tg:-0}" -ge 1 ]; then echo "PASS  image $n: $tg analysed targets, $s"; else echo "FAIL  image $n: no analysed target, the scan proves nothing"; exit 1; fi
else
  echo "FAIL  image $n: trivy failed: $(tail -n 1 "$t/err.txt" | cut -c1-160)"; exit 1
fi
