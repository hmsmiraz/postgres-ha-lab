#!/usr/bin/env bash
# REP-3: replication slots exist and are healthy; WAL retention is capped.
set -euo pipefail
NS=pg-ha
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

leader=$(kubectl -n "$NS" get pods -l application=pg-ha,role=primary -o jsonpath='{.items[0].metadata.name}')
sql() { kubectl -n "$NS" exec "$leader" -c postgres -- psql -U postgres -Atq -v ON_ERROR_STOP=1 -c "$1"; }

echo "date: $(date -u +%FT%TZ)"
echo "leader: $leader"
sql "select slot_name, slot_type, active, wal_status from pg_replication_slots order by 1"

active=$(sql "select count(*) from pg_replication_slots where slot_type = 'physical' and active")
[ "$active" = 2 ] || fail "expected 2 active physical slots, found $active"
pass "2 active physical slots (one per replica)"

bad=$(sql "select count(*) from pg_replication_slots where wal_status <> 'reserved'")
[ "$bad" = 0 ] || fail "$bad slot(s) not in wal_status 'reserved'"
pass "all slots have wal_status = reserved"

cap=$(sql "show max_slot_wal_keep_size")
echo "max_slot_wal_keep_size = $cap"
[ "$cap" = "1GB" ] || fail "max_slot_wal_keep_size is $cap, expected 1GB"
pass "slot WAL retention is capped at 1GB"
echo "ALL CHECKS PASSED"
