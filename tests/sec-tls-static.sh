#!/usr/bin/env bash
# SEC-2 (static): TLS settings in k8s/pg/20-config.yaml, the Secret mount in 50-statefulset.yaml, the generator call in pg-up.sh.
# Nothing is created in the cluster. Every "must be zero" check also requires a non-empty file.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
cfg=k8s/pg/20-config.yaml; sts=k8s/pg/50-statefulset.yaml; up=scripts/pg-up.sh
fail=0
pass() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
cnt() { local n; n=$(grep -cE -- "$2" "$1" 2>/dev/null || true); echo "${n:-0}"; }
atleast() { local n; n=$(cnt "$2" "$3"); if [ "$n" -ge "$4" ]; then pass "$1 ($n)"; else bad "$1 (found $n, need $4)"; fi; }
zero() { local n; n=$(cnt "$2" "$3"); if [ -s "$2" ] && [ "$n" -eq 0 ]; then pass "$1"; else bad "$1 (file empty or found $n)"; fi; }

echo "date_utc: $(date -u +%FT%TZ)"
atleast "pg_hba has 4 hostssl rules" "$cfg" '^ +- hostssl ' 4
zero "pg_hba has no plain host rule" "$cfg" '^ +- host '
atleast "ssl is on" "$cfg" '^ +ssl: "on"$' 1
atleast "ssl_cert_file is /tls/tls.crt" "$cfg" 'ssl_cert_file: /tls/tls.crt' 1
atleast "ssl_key_file is /tls/tls.key" "$cfg" 'ssl_key_file: /tls/tls.key' 1
atleast "replication uses sslmode verify-ca" "$cfg" 'sslmode: verify-ca' 1
atleast "replication has sslrootcert /tls/ca.crt" "$cfg" 'sslrootcert: /tls/ca.crt' 1
atleast "statefulset uses the Secret pg-tls" "$sts" 'secretName: pg-tls' 1
atleast "statefulset mounts /tls in postgres and pgserver" "$sts" '^ +mountPath: /tls$' 2
atleast "pg-up.sh calls the pg-tls generator" "$up" 'gen-pg-tls\.sh' 1

ctl=$(mktemp); printf 'zzqx\n' > "$ctl"
n=$(grep -cE -- zzqx "$ctl" || true); rm -f "$ctl"
if [ "${n:-0}" -eq 1 ]; then pass "control: the counter sees a known string"; else bad "control: the counter sees a known string"; fi
exit "$fail"
