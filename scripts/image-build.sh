#!/usr/bin/env bash
# Build the Postgres + Patroni + pgBackRest image from pinned versions.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source versions.env

docker build -f image/Dockerfile \
  --build-arg BASE_IMAGE="$POSTGRES_BASE_IMAGE" \
  --build-arg PGBACKREST_APT_VERSION="$PGBACKREST_APT_VERSION" \
  --build-arg PATRONI_VERSION="$PATRONI_VERSION" \
  --build-arg POSTGRES_VERSION="$POSTGRES_VERSION" \
  -t "${IMAGE_NAME}:${IMAGE_TAG}" .
