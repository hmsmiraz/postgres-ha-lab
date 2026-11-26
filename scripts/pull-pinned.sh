#!/usr/bin/env bash
# Loaders need the tag in Docker's image store. Resolve it from the pinned digest.
set -euo pipefail
for pin in "$@"; do
  [[ "$pin" == *@sha256:* ]] || { echo "Image digest required: $pin" >&2; exit 2; }
  # Strip the tag using the digest and final colon to support registry ports.
  tag=${pin%@*}
  ref="${tag%:*}@${pin#*@}"
  if ! docker image inspect "$ref" >/dev/null 2>&1; then
    docker pull "$pin"
  fi
  docker tag "$ref" "$tag"
done
