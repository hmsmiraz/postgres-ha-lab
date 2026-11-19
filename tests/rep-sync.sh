#!/usr/bin/env bash
# REP-2: synchronous replication with one sync standby.
set -euo pipefail
NS=pg-ha
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

leader=$(kubectl -n "$NS" get pods -l application=pg-ha,role=primary -o jsonpath='{.items[0].metadata.name}')
sql() { kubectl -n "$NS" exec "$leader" -c postgres -- psql -U postgres -d appdb -Atq -v ON_ERROR_STOP=1 -c "$1"; }

echo "date: $(date -u +%FT%TZ)"
echo "leader: $leader"

names=$(sql "show synchronous_standby_names")
echo "synchronous_standby_names = $names"
[ -n "$names" ] || fail "synchronous_standby_names is empty"
pass "synchronous_standby_names is set"

[ "$(sql "show synchronous_commit")" = "on" ] || fail "synchronous_commit is not on"
pass "synchronous_commit = on"

count=$(sql "select count(*) from pg_stat_replication where sync_state = 'sync'")
[ "$count" = 1 ] || fail "expected 1 sync standby, found $count"
pass "exactly 1 sync standby in pg_stat_replication"

sql "create table if not exists sync_probe(i int)" >/dev/null
# In one session: note the WAL position before COMMIT, commit, then check the
# sync standby had already flushed at least that position when COMMIT returned.
flushed=$(kubectl -n "$NS" exec -i "$leader" -c postgres -- psql -U postgres -d appdb -Atq -v ON_ERROR_STOP=1 <<'SQL'
begin;
insert into sync_probe values (1);
select pg_current_wal_insert_lsn() as pre_commit_lsn \gset
commit;
select count(*) from pg_stat_replication where sync_state = 'sync' and flush_lsn >= :'pre_commit_lsn';
SQL
)
[ "$flushed" = 1 ] || fail "sync standby had not flushed the commit when COMMIT returned"
pass "sync standby had flushed the WAL when COMMIT returned"
echo "ALL CHECKS PASSED"
