#!/usr/bin/env bash
# Probe images: anonymous pull, digest, size and runtime config. Usage: probe-image.sh OUTFILE IMAGE...
set -euo pipefail
[ "$#" -ge 2 ] || { echo "usage: $0 OUTFILE IMAGE..." >&2; exit 2; }
out=$1; shift
DOCKER_CONFIG="$(mktemp -d)"
export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
{
  echo "# image probe (anonymous pulls)"
  echo "date_utc: $(date -u +%FT%TZ)"
  for img in "$@"; do
    echo "--- $img"
    if msg=$(docker pull "$img" 2>&1); then
      echo "RESULT: pulled"
      docker image inspect --format 'digest: {{index .RepoDigests 0}}' "$img"
      docker image inspect --format 'created: {{.Created}} arch: {{.Architecture}} size: {{.Size}}' "$img"
      docker image inspect --format 'user={{.Config.User}} entrypoint={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}} ports={{json .Config.ExposedPorts}}' "$img"
    else
      echo "RESULT: FAILED"
      echo "$msg" | tail -n 3
    fi
  done
} | tee "$out"
