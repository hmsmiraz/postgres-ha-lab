#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source versions.env
docker run --rm --entrypoint sh "${OBJSTORE_PROXY_RUNTIME_IMAGE:?missing proxy image pin}" -ec '
  test "$(id -u)" -ne 0
  nginx -v
  for pin do
    apk info -e "$pin" >/dev/null || exit 1
    echo "PASS $pin"
  done
' sh ${OBJSTORE_PROXY_APK_PACKAGES:?missing package pins}
