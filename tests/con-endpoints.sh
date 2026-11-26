#!/usr/bin/env bash
# CON-1: pg-primary always reaches the primary. CON-2: pg-replica reaches replicas only.
set -euo pipefail
NS=pg-ha
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# Use the opposite role as the client so a Service never loops back to the client pod.
# Single quotes are intended: the variables expand inside the pod, not here.
# shellcheck disable=SC2016
q() {
  local role=replica client
  if [[ "$1" == pg-replica ]]; then role=primary; fi
  client=$(kubectl -n "$NS" get pods -l "cluster-name=pg-ha,role=$role" -o jsonpath='{.items[0].metadata.name}') || return 1
  kubectl -n "$NS" exec -i "$client" -c postgres -- sh -c \
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
