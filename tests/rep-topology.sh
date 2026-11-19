#!/usr/bin/env bash
# REP-1: 1 primary + 2 streaming replicas, PostgreSQL >= 15.
set -euo pipefail
NS=pg-ha
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }
ctl() { kubectl -n "$NS" exec pg-ha-0 -c postgres -- patronictl -c /etc/patroni/patroni.yml "$@"; }

echo "date: $(date -u +%FT%TZ)"
leaders=0; followers=0
deadline=$((SECONDS + 300))
while [ "$SECONDS" -lt "$deadline" ]; do
  state=$(ctl list -f json 2>/dev/null || true)
  leaders=$(jq '[.[] | select(.Role == "Leader")] | length' <<<"$state" 2>/dev/null || echo 0)
  followers=$(jq '[.[] | select((.Role == "Replica" or .Role == "Sync Standby") and .State == "streaming")] | length' <<<"$state" 2>/dev/null || echo 0)
  if [ "$leaders" = 1 ] && [ "$followers" = 2 ]; then break; fi
  sleep 5
done

ctl list || true
[ "$leaders" = 1 ] || fail "expected 1 leader, found $leaders"
pass "1 leader"
[ "$followers" = 2 ] || fail "expected 2 streaming replicas, found $followers"
pass "2 streaming replicas"

ver=$(kubectl -n "$NS" exec pg-ha-0 -c postgres -- psql -U postgres -Atc "show server_version_num")
[ "$ver" -ge 150000 ] || fail "PostgreSQL version $ver is older than 15"
pass "PostgreSQL version number $ver (>= 15)"
echo "ALL CHECKS PASSED"
