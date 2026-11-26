#!/usr/bin/env bash
# Acceptance test: the custom image has the pinned tools and runs as non-root.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source versions.env

IMG="${IMAGE_NAME}:${IMAGE_TAG}"
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }
run() { docker run --rm --entrypoint "$@"; }

echo "date: $(date -u +%FT%TZ)"
echo "image: $IMG"

docker image inspect "$IMG" >/dev/null 2>&1 || fail "image $IMG does not exist"
pass "image exists"

uid=$(run id "$IMG" -u)
[ "$uid" != "0" ] || fail "image runs as root"
pass "runs as non-root (uid $uid)"

out=$(run postgres "$IMG" --version)
echo "$out"
echo "$out" | grep -q "$POSTGRES_VERSION" || fail "postgres is not $POSTGRES_VERSION"
pass "postgres $POSTGRES_VERSION"

out=$(run patroni "$IMG" --version)
echo "$out"
echo "$out" | grep -q "$PATRONI_VERSION" || fail "patroni is not $PATRONI_VERSION"
pass "patroni $PATRONI_VERSION"

out=$(run pgbackrest "$IMG" version)
echo "$out"
echo "$out" | grep -q "${PGBACKREST_APT_VERSION%%-*}" || fail "pgbackrest is not ${PGBACKREST_APT_VERSION%%-*}"
pass "pgbackrest ${PGBACKREST_APT_VERSION%%-*}"

run pg_rewind "$IMG" --version >/dev/null || fail "pg_rewind missing"
pass "pg_rewind present"

run tini "$IMG" --version >/dev/null || fail "tini missing"
pass "tini present"

run sh "$IMG" -c '! command -v gosu >/dev/null 2>&1' || fail "unused root-switching helper is installed"
pass "no unused gosu binary in the Patroni runtime"
for pkg in libzstd1 zstd; do
  actual=$(run dpkg-query "$IMG" -W -f='${Version}' "$pkg")
  [ "$actual" = "$ZSTD_APT_VERSION" ] || fail "$pkg version differs from the security pin"
done
pass "both zstd packages match the security pin"
echo "ALL CHECKS PASSED"
