#!/usr/bin/env bash
# SEC-2: TLS for client and replication traffic. Live and read-only. Prints booleans and counts, no secret.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
NS=pg-ha
fail=0
ok() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
q() { kubectl -n "$NS" exec "$1" -c postgres -- psql -U postgres -Atqc "$2" 2>/dev/null | tr -d ' \n'; }

echo "date_utc: $(date -u +%FT%TZ)"
for p in pg-ha-0 pg-ha-1 pg-ha-2; do
  if [ "$(q "$p" "show ssl")" = on ]; then ok "$p ssl is on"; else bad "$p ssl is on"; fi
  n=$(q "$p" "select count(*) from pg_hba_file_rules where type = 'host'")
  if [ "$n" = 0 ]; then ok "$p has no non-SSL host rule"; else bad "$p has no non-SSL host rule (found ${n:-unknown})"; fi
done

keys=$(kubectl -n "$NS" get secret pg-tls -o json 2>/dev/null | jq -c '[.data | keys[]] | sort' 2>/dev/null || true)
if [ "$keys" = '["ca.crt","tls.crt","tls.key"]' ]; then ok "Secret pg-tls holds exactly ca.crt, tls.crt, tls.key"; else bad "Secret pg-tls holds exactly ca.crt, tls.crt, tls.key"; fi

# shellcheck disable=SC2016
client() { kubectl -n "$NS" exec pg-ha-0 -c postgres -- env MODE="$1" sh -c 'PGCONNECT_TIMEOUT=3 PGPASSWORD="$APP_PASSWORD" psql "host=pg-primary dbname=appdb user=app sslmode=$MODE" -Atqc "select ssl from pg_stat_ssl where pid = pg_backend_pid()"' 2>/dev/null | tr -d ' \n'; }
if [ "$(client require)" = t ]; then ok "client connection with sslmode=require uses TLS"; else bad "client connection with sslmode=require uses TLS"; fi
if [ -z "$(client disable)" ]; then ok "client connection with sslmode=disable is rejected"; else bad "client connection with sslmode=disable is rejected"; fi

checked=0; good=0
for p in pg-ha-0 pg-ha-1 pg-ha-2; do
  if [ "$(q "$p" "select pg_is_in_recovery()")" = t ]; then
    checked=$((checked + 1))
    if [ "$(q "$p" "select position('sslmode=verify-ca' in current_setting('primary_conninfo')) > 0")" = t ]; then good=$((good + 1)); fi
  fi
done
if [ "$checked" -ge 2 ] && [ "$good" = "$checked" ]; then ok "replicas use sslmode=verify-ca ($good of $checked)"; else bad "replicas use sslmode=verify-ca ($good of $checked)"; fi

leader=$(kubectl -n "$NS" get pods -l application=pg-ha,role=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
tot=$(q "$leader" "select count(*) from pg_stat_replication")
nossl=$(q "$leader" "select count(*) from pg_stat_replication r join pg_stat_ssl s using(pid) where not s.ssl")
if [ "${tot:-0}" -ge 1 ] && [ "$nossl" = 0 ]; then ok "all $tot walsender connections use TLS"; else bad "all walsender connections use TLS (total ${tot:-0}, without TLS ${nossl:-unknown})"; fi

if [ "$(q pg-ha-0 "select ssl from pg_stat_ssl where pid = pg_backend_pid()")" = f ]; then ok "control: a local socket connection reports ssl false"; else bad "control: a local socket connection reports ssl false"; fi
exit "$fail"
