#!/usr/bin/env bash
# OBJ-2 (generator part): scripts/gen-objstore-secrets.sh creates the three object store Secrets once, never prints
# their values, leaves no key material on disk, keeps existing Secrets on a rerun, and the certificate chain is sound.
# Runs in a scratch namespace so it never touches the Secrets of a live object store.
set -euo pipefail
cd "$(dirname "$0")/.."

NS=objsec-test
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }
k() { kubectl -n "$NS" "$@"; }
field() { k get secret "$1" -o json | jq -r --arg key "$2" '.data[$key] // empty' | base64 -d; }
keys_of() { k get secret "$1" -o json 2>/dev/null | jq -c '[.data | keys[]] | sort'; }
snapshot() {
  kubectl -n "$NS" get secret objstore-credentials objstore-admin objstore-tls -o json \
    | jq -c '[.items[] | {n: .metadata.name, d: .data}] | sort_by(.n)' | sha256sum | cut -d' ' -f1
}

umask 077
work=$(mktemp -d)
gentmp=$(mktemp -d)
cleanup() {
  rm -rf "$work" "$gentmp"
  kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "date: $(date -u +%FT%TZ)"
[ -x scripts/gen-objstore-secrets.sh ] || fail "scripts/gen-objstore-secrets.sh does not exist or is not executable"
pass "generator script is present and executable"

kubectl delete ns "$NS" --ignore-not-found --wait=true >/dev/null
kubectl create ns "$NS" >/dev/null

if ! out1=$(NS="$NS" TMPDIR="$gentmp" scripts/gen-objstore-secrets.sh 2>&1); then
  echo "$out1" | tail -n 5
  fail "generator failed on the first run"
fi
[ "$(grep -c ' created$' <<<"$out1")" -eq 3 ] || fail "first run must report exactly three Secrets created"
pass "first run created three Secrets"

[ "$(keys_of objstore-credentials)" = '["access-key-id","secret-access-key"]' ] || fail "objstore-credentials keys are wrong"
[ "$(keys_of objstore-admin)" = '["admin-token","rpc-secret"]' ] || fail "objstore-admin keys are wrong"
[ "$(keys_of objstore-tls)" = '["ca.crt","tls.crt","tls.key"]' ] || fail "objstore-tls must hold exactly ca.crt, tls.crt and tls.key (no CA private key)"
pass "Secret keys are exactly as the contract says (no CA private key in the cluster)"

ak=$(field objstore-credentials access-key-id)
sk=$(field objstore-credentials secret-access-key)
tok=$(field objstore-admin admin-token)
rpc=$(field objstore-admin rpc-secret)
[[ "$ak" =~ ^GK[0-9a-f]{24}$ ]] || fail "access-key-id is not GK plus 24 hex characters"
[[ "$sk" =~ ^[0-9a-f]{64}$ ]] || fail "secret-access-key is not 64 hex characters"
[[ "$rpc" =~ ^[0-9a-f]{64}$ ]] || fail "rpc-secret is not 64 hex characters"
[ "${#tok}" -ge 32 ] || fail "admin-token is shorter than 32 characters"
[ "$(printf '%s\n%s\n%s\n%s\n' "$ak" "$sk" "$tok" "$rpc" | sort -u | wc -l)" -eq 4 ] || fail "two generated values are identical"
pass "value formats are right and all four values are distinct (values not printed)"

field objstore-tls ca.crt >"$work/ca.crt"
field objstore-tls tls.crt >"$work/tls.crt"
field objstore-tls tls.key >"$work/tls.key"
openssl verify -CAfile "$work/ca.crt" "$work/tls.crt" >/dev/null 2>&1 || fail "server certificate does not verify against ca.crt"
pass "server certificate verifies against ca.crt"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=unrelated-ca" \
  -keyout "$work/other.key" -out "$work/other.crt" >/dev/null 2>&1
if openssl verify -CAfile "$work/other.crt" "$work/tls.crt" >/dev/null 2>&1; then
  fail "negative control: the server certificate verified against an unrelated CA"
fi
pass "negative control: an unrelated CA does not verify the server certificate"

names=$(openssl x509 -in "$work/tls.crt" -noout -ext subjectAltName | grep -o 'DNS:[^, ]*' | sed 's/^DNS://')
for n in objstore "objstore.$NS" "objstore.$NS.svc" "objstore.$NS.svc.cluster.local"; do
  grep -qx "$n" <<<"$names" || fail "server certificate has no SAN entry for $n"
done
pass "server certificate names the Service in all four forms"

[ "$(openssl x509 -in "$work/tls.crt" -noout -pubkey | sha256sum)" = "$(openssl pkey -in "$work/tls.key" -pubout | sha256sum)" ] \
  || fail "tls.key does not match tls.crt"
openssl x509 -in "$work/tls.crt" -noout -text | grep -q 'CA:FALSE' || fail "the server certificate is marked as a CA"
openssl x509 -in "$work/ca.crt" -noout -text | grep -q 'CA:TRUE' || fail "ca.crt is not marked as a CA"
pass "key matches certificate, server certificate is not a CA, ca.crt is a CA"

openssl x509 -in "$work/tls.crt" -noout -checkend 2592000 >/dev/null || fail "server certificate expires within 30 days"
openssl x509 -in "$work/ca.crt" -noout -checkend 2592000 >/dev/null || fail "CA certificate expires within 30 days"
pass "certificates are valid for more than 30 days"

[ -z "$(ls -A "$gentmp")" ] || fail "the generator left files in its temporary directory"
pass "no key material is left on disk by the generator"

printf '%s\n%s\n%s\n%s\n' "$ak" "$sk" "$tok" "$rpc" >"$work/pat"
grep -F -q -f "$work/pat" <<<"control line with $ak inside" || fail "leak check control did not fire"
if grep -F -q -f "$work/pat" <<<"$out1"; then fail "a generated value appears in the generator output"; fi
pass "no generated value appears in the generator output (control fired)"

before=$(snapshot)
if ! out2=$(NS="$NS" TMPDIR="$gentmp" scripts/gen-objstore-secrets.sh 2>&1); then
  echo "$out2" | tail -n 5
  fail "generator failed on the second run"
fi
[ "$(grep -c 'already exists, keeping it' <<<"$out2")" -eq 3 ] || fail "second run must keep all three Secrets"
[ "$(snapshot)" = "$before" ] || fail "a Secret changed on the second run"
pass "second run keeps all three Secrets unchanged"
echo "ALL CHECKS PASSED"
