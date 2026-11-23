#!/usr/bin/env bash
# SEC-2 (generator part): scripts/gen-pg-tls.sh creates the Secret pg-tls once, prints no key material,
# leaves no file behind, keeps an existing Secret, and the certificate chain and names are right.
# Runs in the scratch namespace pgtls-test, which this test creates and deletes.
set -euo pipefail
cd "$(dirname "$0")/.."

NS=pgtls-test
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; exit 1; }
echo "date_utc: $(date -u +%FT%TZ)"
[ -x scripts/gen-pg-tls.sh ] || fail "scripts/gen-pg-tls.sh does not exist or is not executable"
pass "generator script is present and executable"

if kubectl get ns "$NS" >/dev/null 2>&1; then fail "namespace $NS already exists, refusing to run"; fi
umask 077
work=$(mktemp -d); gentmp=$(mktemp -d)
cleanup() { rm -rf "$work" "$gentmp"; kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT
kubectl create ns "$NS" >/dev/null

field() { kubectl -n "$NS" get secret pg-tls -o json | jq -r --arg k "$1" '.data[$k] // empty' | base64 -d; }

out1=$(NS="$NS" TMPDIR="$gentmp" scripts/gen-pg-tls.sh 2>&1) || { echo "$out1" | tail -n 3; fail "generator failed on the first run"; }
[ "$(grep -c ' created$' <<<"$out1")" -eq 1 ] || fail "first run must report the Secret created"
pass "first run created the Secret"

[ "$(kubectl -n "$NS" get secret pg-tls -o json | jq -c '[.data | keys[]] | sort')" = '["ca.crt","tls.crt","tls.key"]' ] \
  || fail "pg-tls must hold exactly ca.crt, tls.crt and tls.key (no CA private key)"
pass "Secret keys are exactly ca.crt, tls.crt, tls.key"

field ca.crt > "$work/ca.crt"; field tls.crt > "$work/tls.crt"; field tls.key > "$work/tls.key"
openssl verify -CAfile "$work/ca.crt" "$work/tls.crt" >/dev/null 2>&1 || fail "server certificate does not verify against ca.crt"
pass "server certificate verifies against ca.crt"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=unrelated-ca" -keyout "$work/o.key" -out "$work/o.crt" >/dev/null 2>&1
if openssl verify -CAfile "$work/o.crt" "$work/tls.crt" >/dev/null 2>&1; then fail "negative control: an unrelated CA verified the certificate"; fi
pass "negative control: an unrelated CA does not verify the certificate"

names=$(openssl x509 -in "$work/tls.crt" -noout -ext subjectAltName | grep -o 'DNS:[^, ]*' | sed 's/^DNS://')
for n in pg-primary pg-replica localhost "pg-primary.$NS.svc.cluster.local" "pg-ha-0.pg-ha-headless.$NS.svc.cluster.local" \
         "pg-ha-1.pg-ha-headless.$NS.svc.cluster.local" "pg-ha-2.pg-ha-headless.$NS.svc.cluster.local"; do
  grep -qx "$n" <<<"$names" || fail "no SAN entry for $n"
done
pass "SANs name the services, localhost and the three pods"

[ "$(openssl x509 -in "$work/tls.crt" -noout -pubkey | sha256sum)" = "$(openssl pkey -in "$work/tls.key" -pubout | sha256sum)" ] || fail "tls.key does not match tls.crt"
openssl x509 -in "$work/tls.crt" -noout -text | grep -q 'CA:FALSE' || fail "the server certificate is marked as a CA"
openssl x509 -in "$work/ca.crt" -noout -text | grep -q 'CA:TRUE' || fail "ca.crt is not marked as a CA"
openssl x509 -in "$work/tls.crt" -noout -checkend 2592000 >/dev/null || fail "server certificate expires within 30 days"
pass "key matches, server certificate is not a CA, ca.crt is a CA, validity over 30 days"

[ -z "$(ls -A "$gentmp")" ] || fail "the generator left files in its temporary directory"
pass "no key material is left on disk by the generator"
if grep -q -e 'PRIV''ATE' -e 'BEGIN' <<<"$out1"; then fail "the generator printed key material"; fi
pass "the generator output holds no key material"

before=$(kubectl -n "$NS" get secret pg-tls -o json | jq -c '.data' | sha256sum)
out2=$(NS="$NS" TMPDIR="$gentmp" scripts/gen-pg-tls.sh 2>&1) || fail "generator failed on the second run"
[ "$(grep -c 'already exists, keeping it' <<<"$out2")" -eq 1 ] || fail "second run must keep the Secret"
[ "$before" = "$(kubectl -n "$NS" get secret pg-tls -o json | jq -c '.data' | sha256sum)" ] || fail "the Secret changed on the second run"
pass "second run keeps the Secret unchanged"
echo "ALL CHECKS PASSED"
