#!/usr/bin/env bash
# CON-1: pg-primary always reaches the primary. CON-2: pg-replica reaches replicas only.
set -euo pipefail
NS=pg-ha
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# Run SQL as the app user against a service, from inside pg-ha-0.
# Single quotes are intended: the variables expand inside the pod, not here.
# shellcheck disable=SC2016
q() {
  kubectl -n "$NS" exec -i pg-ha-0 -c postgres -- sh -c \
    'PGPASSWORD="$APP_PASSWORD" psql -h "$0" -U app -d appdb -Atq -v ON_ERROR_STOP=1' "$1" <<<"$2"
}

echo "date: $(date -u +%FT%TZ)"
rw=$(q pg-primary "select pg_is_in_recovery()") || fail "cannot connect through pg-primary"
[ "$rw" = "f" ] || fail "pg-primary is in recovery (not a primary): $rw"
pass "pg-primary reaches a primary (pg_is_in_recovery = f)"

q pg-primary "create table if not exists con_probe(id serial primary key, ts timestamptz default now()); insert into con_probe default values;" >/dev/null \
  || fail "write through pg-primary failed"
pass "write through pg-primary works"

ro=$(q pg-replica "select pg_is_in_recovery()") || fail "cannot connect through pg-replica"
[ "$ro" = "t" ] || fail "pg-replica is not a replica: $ro"
pass "pg-replica reaches a replica (pg_is_in_recovery = t)"

if q pg-replica "create table should_fail(i int)" >/dev/null 2>&1; then
  fail "write through pg-replica was accepted"
fi
pass "write through pg-replica is rejected"
echo "ALL CHECKS PASSED"
