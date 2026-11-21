#!/usr/bin/env bash
# BK-1 (v2): continuous WAL archiving to the object store.
# SPEC pass criterion: pgbackrest check succeeds and new WAL objects appear in the repository.
# Also checked: archive_mode is on on every member, archive_command uses pgBackRest and holds no secret value, the stanza
# exists in the repository, the archiver reports no new failures in the test window, and the leak rules of ADR-0005
# amendment 1 hold: the three access-granting values (secret access key, admin token, rpc secret) appear in no repo file,
# evidence file, ConfigMap, Patroni configuration or pg-ha pod log; the access key id appears in no repo file, evidence file,
# ConfigMap or Patroni configuration. v1 (docs/evidence/BK-1-FAILED.txt) also scanned the key id in pod logs.
# Not covered here: archiving after a failover.
# Leak scans use grep -c or -l, never "producer | grep -q" (can miss a match under pipefail).
set -euo pipefail
cd "$(dirname "$0")/.."

NS=pg-ha
STANZA=pg-ha
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }
k() { kubectl -n "$NS" "$@"; }
sql() { local pod=$1; shift; k exec "$pod" -c postgres -- psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At -c "$*"; }
secret_field() { k get secret "$1" -o "jsonpath={.data.$2}" 2>/dev/null | base64 -d; }

pat=$(mktemp)
leader=""
# shellcheck disable=SC2329
cleanup() {
  rm -f "$pat" "$pat.three"
  if [ -n "$leader" ]; then sql "$leader" "drop table if exists bk1_probe" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

echo "date: $(date -u +%FT%TZ)"
k get sts pg-ha >/dev/null 2>&1 || fail "cluster not reachable or StatefulSet pg-ha missing"
k rollout status sts/objstore --timeout=60s >/dev/null 2>&1 || fail "the object store is not ready (run scripts/objstore-up.sh)"
pass "cluster reachable, object store ready"

ak=$(secret_field objstore-credentials access-key-id || true)
sk=$(secret_field objstore-credentials secret-access-key || true)
tok=$(secret_field objstore-admin admin-token || true)
rpc=$(secret_field objstore-admin rpc-secret || true)
for v in "$ak" "$sk" "$tok" "$rpc"; do
  [ -n "$v" ] || fail "a required Secret value is missing (objstore-credentials or objstore-admin)"
done
( umask 077; printf '%s\n%s\n%s\n%s\n' "$ak" "$sk" "$tok" "$rpc" >"$pat"; printf '%s\n%s\n%s\n' "$sk" "$tok" "$rpc" >"$pat.three" )
n=$(printf 'control line with %s inside\n' "$sk" | grep -F -c -f "$pat.three" || true)
[ "${n:-0}" = 1 ] || fail "leak scanner control did not fire on a planted secret value"
n=$(printf 'control line with %s inside\n' "$ak" | grep -F -c -f "$pat.three" || true)
[ "${n:-0}" = 0 ] || fail "leak scanner control: the three-value pattern matches the access key id, which it must not"
pass "secret values loaded (not printed); the log scanner fires on a planted secret and ignores the access key id"

state=$(k exec pg-ha-0 -c postgres -- patronictl -c /etc/patroni/patroni.yml list -f json 2>/dev/null || true)
leader=$(jq -r '[.[] | select(.Role == "Leader")][0].Member // empty' <<<"$state" 2>/dev/null || true)
members=$(jq -r '.[].Member' <<<"$state" 2>/dev/null || true)
streaming=$(jq '[.[] | select((.Role == "Replica" or .Role == "Sync Standby") and .State == "streaming")] | length' <<<"$state" 2>/dev/null || echo 0)
[ -n "$leader" ] || fail "no Patroni leader found"
[ "$streaming" = 2 ] || fail "expected 2 streaming replicas, found $streaming"
pass "leader is $leader, 2 streaming replicas"

for p in $members; do
  mode=$(sql "$p" "show archive_mode" 2>/dev/null || true)
  [ "$mode" = on ] || fail "archive_mode is '${mode:-unknown}' on $p, expected on"
done
pass "archive_mode is on on every member (a promoted replica archives too)"

cmd=$(sql "$leader" "show archive_command")
n=$(grep -F -c -f "$pat" <<<"$cmd" || true)
[ "${n:-0}" = 0 ] || fail "archive_command contains a secret value or the access key id"
case "$cmd" in
  *"pgbackrest"*"--stanza=$STANZA"*"archive-push"*) pass "archive_command uses pgBackRest archive-push for stanza $STANZA and holds no secret" ;;
  *) fail "archive_command is not 'pgbackrest --stanza=$STANZA archive-push %p'" ;;
esac

stanza=no
for _ in $(seq 1 90); do
  listing=$(k exec "$leader" -c postgres -- pgbackrest repo-ls "backup/$STANZA" 2>/dev/null </dev/null || true)
  case "$listing" in *backup.info*) stanza=yes; break ;; esac
  sleep 2
done
[ "$stanza" = yes ] || fail "stanza $STANZA does not exist in the repository after 180 s"
pass "stanza $STANZA exists in the repository"

before_failed=$(sql "$leader" "select failed_count from pg_stat_archiver")
before_count=$(sql "$leader" "select archived_count from pg_stat_archiver")
if ! out=$(k exec "$leader" -c postgres -- pgbackrest --stanza="$STANZA" check 2>&1); then
  echo "$out" | tail -n 8
  fail "pgbackrest check failed on $leader"
fi
pass "pgbackrest check succeeds on $leader"

sql "$leader" "create table if not exists bk1_probe(t timestamptz default now(), v text)" >/dev/null
sql "$leader" "insert into bk1_probe(v) select md5(g::text) from generate_series(1,20000) g" >/dev/null
seg=$(sql "$leader" "select pg_walfile_name(pg_current_wal_lsn())")
sql "$leader" "select pg_switch_wal()" >/dev/null
found=no
for _ in $(seq 1 45); do
  listing=$(k exec "$leader" -c postgres -- pgbackrest repo-ls "archive/$STANZA" --recurse 2>/dev/null </dev/null || true)
  if grep -qF "$seg" <<<"$listing"; then found=yes; break; fi
  sleep 2
done
[ "$found" = yes ] || fail "WAL segment $seg did not appear in the repository within 90 s"
pass "WAL segment $seg appeared in the repository after pg_switch_wal"

after_failed=$(sql "$leader" "select failed_count from pg_stat_archiver")
after_count=$(sql "$leader" "select archived_count from pg_stat_archiver")
[ "$after_count" -gt "$before_count" ] || fail "archived_count did not increase (before $before_count, after $after_count)"
[ "$after_failed" = "$before_failed" ] || fail "archive failures grew during the test (before $before_failed, after $after_failed)"
pass "archived_count rose from $before_count to $after_count and failed_count stayed at $after_failed"

files=$(git grep --untracked -I -F -l -f "$pat" || true)
if [ -n "$files" ]; then
  while IFS= read -r fname; do echo "  file: $fname"; done <<<"$files"
  fail "a secret value or the access key id was found in a repo file (names listed above, no content)"
fi
pass "none of the four values in any repo file (working tree only, not history)"
files=$(grep -r -F -l -f "$pat" docs/evidence 2>/dev/null || true)
if [ -n "$files" ]; then
  while IFS= read -r fname; do echo "  file: $fname"; done <<<"$files"
  fail "a secret value or the access key id was found in an evidence file (names listed above, no content)"
fi
pass "none of the four values in any file under docs/evidence"

leak=0
n=$(k exec pg-ha-0 -c postgres -- patronictl -c /etc/patroni/patroni.yml show-config 2>/dev/null | grep -F -c -f "$pat" || true)
if [ "${n:-0}" != 0 ]; then leak=1; fi
n=$(k get configmap -o json 2>/dev/null | grep -F -c -f "$pat" || true)
if [ "${n:-0}" != 0 ]; then leak=1; fi
[ "$leak" -eq 0 ] || fail "a secret value or the access key id was found in the Patroni configuration or a ConfigMap"
pass "none of the four values in the Patroni configuration or any ConfigMap"
for p in $members; do
  n=$(k logs "$p" --all-containers 2>&1 | grep -F -c -f "$pat.three" || true)
  if [ "${n:-0}" != 0 ]; then leak=1; fi
done
[ "$leak" -eq 0 ] || fail "the secret access key, the admin token or the rpc secret was found in a pg-ha pod log"
pass "none of the three access-granting values in any pg-ha pod log"
n=0
for p in $members; do
  c=$(k logs "$p" --all-containers 2>&1 | grep -F -c -e "$ak" || true)
  n=$((n + ${c:-0}))
done
echo "INFO: the access key id appears in $n lines of the pg-ha pod logs (count only)"
echo "ALL CHECKS PASSED"
