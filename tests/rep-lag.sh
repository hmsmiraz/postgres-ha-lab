#!/usr/bin/env bash
# REP-4: replication lag is measured, in bytes and in time.
set -euo pipefail
NS=pg-ha
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

leader=$(kubectl -n "$NS" get pods -l application=pg-ha,role=primary -o jsonpath='{.items[0].metadata.name}')
sql() { kubectl -n "$NS" exec "$leader" -c postgres -- psql -U postgres -d appdb -Atq -v ON_ERROR_STOP=1 -c "$1"; }

echo "date: $(date -u +%FT%TZ)"
echo "leader: $leader"
sql "create table if not exists sync_probe(i int)" >/dev/null
sql "insert into sync_probe values (2)" >/dev/null

echo "replica | replay_lag_bytes | replay_lag_time"
rows=$(sql "select application_name, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint, coalesce(replay_lag::text, 'n/a') from pg_stat_replication order by 1")
echo "$rows"

n=$(grep -c . <<<"$rows")
[ "$n" = 2 ] || fail "expected lag rows for 2 replicas, got $n"
pass "lag reported for 2 replicas"

while IFS='|' read -r name bytes _; do
  [[ "$bytes" =~ ^[0-9]+$ ]] || fail "lag in bytes for $name is not a number: $bytes"
done <<<"$rows"
pass "lag in bytes is a number for every replica"
echo "ALL CHECKS PASSED"
