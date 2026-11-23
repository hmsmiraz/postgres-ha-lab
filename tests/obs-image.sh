#!/usr/bin/env bash
# OBS-1 (decisions D1 to D4 and Grafana): the four monitoring images are pinned (tag + digest) and pull anonymously.
# Modelled on tests/obj-image.sh: every condition runs inline and a non-empty sha256 digest is required.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
report() {
  if [ "$2" -eq 0 ]; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi
}

check_image() {
  local var=$1 img cfg want rc
  img=$(sed -nE "s/^(export )?${var}=//p" versions.env | tr -d "\"'" | tail -n 1)
  want=${img##*@}
  echo "=== ${var}=${img:-<unset>}"

  rc=1; if [ -n "$img" ]; then rc=0; fi
  report "$var is defined in versions.env" "$rc"

  rc=1; if [[ "$img" =~ ^[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]]; then rc=0; fi
  report "$var is pinned as name:tag@sha256:<64 hex>" "$rc"

  rc=1; if [ -n "$img" ] && [[ "$img" != *:latest* ]]; then rc=0; fi
  report "$var tag is not latest" "$rc"

  rc=1
  if [ -n "$img" ]; then
    cfg=$(mktemp -d)
    if DOCKER_CONFIG="$cfg" docker pull "$img" >/dev/null 2>&1; then rc=0; fi
    rm -rf "$cfg"
  fi
  report "$var pulls anonymously" "$rc"

  rc=1
  if [ -n "$img" ] && [[ "$want" == sha256:* ]] \
     && docker image inspect --format '{{join .RepoDigests " "}}' "$img" 2>/dev/null | grep -qF "$want"; then
    rc=0
  fi
  report "$var pulled digest equals pinned digest" "$rc"
}

echo "date_utc: $(date -u +%FT%TZ)"
check_image PROMETHEUS_IMAGE
check_image PG_EXPORTER_IMAGE
check_image KSM_IMAGE
check_image GRAFANA_IMAGE
exit "$fail"
