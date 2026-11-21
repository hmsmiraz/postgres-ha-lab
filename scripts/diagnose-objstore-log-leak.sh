#!/usr/bin/env bash
# Finds which log holds which of the four object store secret values. Prints per-source counts only
# (no log lines, because they would contain the values). Read-only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
NS=pg-ha
k() { kubectl -n "$NS" "$@"; }
sf() { k get secret "$1" -o "jsonpath={.data.$2}" 2>/dev/null | base64 -d; }
ak=$(sf objstore-credentials access-key-id)
sk=$(sf objstore-credentials secret-access-key)
tok=$(sf objstore-admin admin-token)
rpc=$(sf objstore-admin rpc-secret)
for v in "$ak" "$sk" "$tok" "$rpc"; do [ -n "$v" ] || { echo "a value is missing"; exit 1; }; done
scan() {
  local label=$1 text name val pair n
  text=$(cat)
  echo "--- $label ($(wc -l <<<"$text") lines)"
  for pair in "access-key-id:$ak" "secret-access-key:$sk" "admin-token:$tok" "rpc-secret:$rpc"; do
    name=${pair%%:*}
    val=${pair#*:}
    n=$(grep -F -c -e "$val" <<<"$text" || true)
    echo "  $name: $n matching lines"
  done
}
echo "date_utc: $(date -u +%FT%TZ)"
k logs objstore-0 -c garage 2>&1 | scan "objstore-0 / garage"
k logs objstore-0 -c tls 2>&1 | scan "objstore-0 / tls (nginx)"
k logs objstore-0 -c init-dirs 2>&1 | scan "objstore-0 / init-dirs"
k logs job/objstore-init 2>&1 | scan "job objstore-init"
echo "DIAGNOSIS DONE"
