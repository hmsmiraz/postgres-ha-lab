#!/usr/bin/env bash
set -euo pipefail
out=docs/evidence/ADR-0004-image-probe.txt
DOCKER_CONFIG="$(mktemp -d)"
export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
candidates=(
  "docker.io/minio/minio:RELEASE.2025-09-07T16-13-09Z"
  "quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z"
  "docker.io/dxflrs/garage:v2.2.0"
  "docker.io/dxflrs/garage:v2.4.1"
  "docker.io/dxflrs/garage:v2.5.0"
)
{
  echo "# ADR-0004 image probe (anonymous pulls)"
  echo "date_utc: $(date -u +%FT%TZ)"
  for img in "${candidates[@]}"; do
    echo "--- $img"
    if msg=$(docker pull "$img" 2>&1); then
      echo "RESULT: pulled"
      docker image inspect --format 'digest: {{index .RepoDigests 0}}' "$img"
      docker image inspect --format 'created: {{.Created}} arch: {{.Architecture}} size: {{.Size}}' "$img"
    else
      echo "RESULT: FAILED"
      echo "$msg" | tail -n 3
    fi
  done
  echo "--- Garage release tags on Docker Hub (newest few)"
  curl -fsS "https://hub.docker.com/v2/repositories/dxflrs/garage/tags?page_size=50&ordering=last_updated" \
    | grep -o '"name":"v[0-9][0-9.]*"' | sort -uV | tail -n 5 \
    || echo "tag listing failed"
} | tee "$out"
