#!/usr/bin/env bash
# OBJ-1 (v2, ADR-0004 and ADR-0005): the object store image and its TLS proxy image are pinned
# (tag + digest) and pull anonymously.
# v1 passed the digest check for an unset variable. v2 requires a non-empty sha256 digest
# and runs every condition inline, so an empty value cannot pass.
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
check_image OBJSTORE_IMAGE
check_image OBJSTORE_TLS_PROXY_IMAGE
exit "$fail"
