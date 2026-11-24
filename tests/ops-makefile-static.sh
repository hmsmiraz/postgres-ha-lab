#!/usr/bin/env bash
# OPS-1/2 (static): the Makefile has the required targets, the right bring-up order, and a down that never deletes the kind cluster.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
m=Makefile
fail=0
pass() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
echo "date_utc: $(date -u +%FT%TZ)"
if [ -s "$m" ]; then pass "Makefile exists and is not empty"; else bad "Makefile exists and is not empty"; fi
for t in up down test-quick test pull; do
  n=$(grep -cE "^${t}:" "$m" 2>/dev/null || true)
  if [ "${n:-0}" -eq 1 ]; then pass "target $t exists"; else bad "target $t exists (found ${n:-0})"; fi
done
# order of the bring-up scripts inside the up recipe
ord=$(awk '/^up:/{f=1;next} /^[a-z-]+:/{f=0} f' "$m" 2>/dev/null | grep -oE 'cluster-up|image-build|objstore-up|pg-up|obs-up' | tr '\n' ' ')
if [ "$ord" = "cluster-up image-build objstore-up pg-up obs-up " ]; then pass "up runs cluster-up, image-build, objstore-up, pg-up, obs-up in order"; else bad "up order is '${ord:-none}'"; fi
n=$(awk '/^down:/{f=1;next} /^[a-z-]+:/{f=0} f' "$m" 2>/dev/null | grep -c 'restore-down' || true)
if [ "${n:-0}" -ge 1 ]; then pass "down calls restore-down.sh"; else bad "down calls restore-down.sh"; fi
n=$(awk '/^down:/{f=1;next} /^[a-z-]+:/{f=0} f' "$m" 2>/dev/null | grep -c 'delete namespace pg-ha\|delete ns pg-ha' || true)
if [ "${n:-0}" -ge 1 ]; then pass "down deletes the namespace pg-ha"; else bad "down deletes the namespace pg-ha"; fi
n=$(grep -c 'kind delete' "$m" 2>/dev/null || true)
if [ -s "$m" ] && [ "${n:-1}" -eq 0 ]; then pass "no kind delete anywhere in the Makefile"; else bad "no kind delete anywhere in the Makefile (found ${n:-unknown}, or empty file)"; fi
n=$(grep -c ':latest' "$m" 2>/dev/null || true)
if [ -s "$m" ] && [ "${n:-1}" -eq 0 ]; then pass "no latest tag in the Makefile"; else bad "no latest tag in the Makefile"; fi
n=$(awk '/^test-quick:/{f=1;next} /^[a-z-]+:/{f=0} f' "$m" 2>/dev/null | grep -c 'tests/' || true)
if [ "${n:-0}" -ge 5 ]; then pass "test-quick runs at least 5 tests"; else bad "test-quick runs at least 5 tests (found ${n:-0})"; fi
ctl=$(mktemp); printf 'zzqx\n' > "$ctl"; n=$(grep -c zzqx "$ctl" || true); rm -f "$ctl"
if [ "${n:-0}" -eq 1 ]; then pass "control: the counter sees a known string"; else bad "control: the counter sees a known string"; fi
exit "$fail"
