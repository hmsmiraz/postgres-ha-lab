#!/usr/bin/env bash
# BK-2 (certificate part, ADR-0002): scripts/gen-pgbackrest-tls.sh creates the TLS material for pgBackRest server mode.
# Contract: two Secrets, pgbackrest-tls-server and pgbackrest-tls-client, each holding exactly ca.crt, tls.crt and tls.key
# (no CA private key in the cluster). The server certificate names the three pod DNS names behind pg-ha-headless and is
# valid for server use only. The client certificate has the fixed name pgbackrest-backup and is valid for client use only.
# A rerun keeps both Secrets. Nothing printed holds key content and no key material stays on disk.
# Runs in a scratch namespace, never in pg-ha. Leak scans use grep -c, never "producer | grep -q".
set -euo pipefail
cd "$(dirname "$0")/.."

NS=pgtls-test
SRV=pgbackrest-tls-server
CLI=pgbackrest-tls-client
CLIENT_CN=pgbackrest-backup
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }
k() { kubectl -n "$NS" "$@"; }
field() { k get secret "$1" -o json | jq -r --arg key "$2" '.data[$key] // empty' | base64 -d; }
keys_of() { k get secret "$1" -o json 2>/dev/null | jq -c '[.data | keys[]] | sort'; }
snapshot() {
  kubectl -n "$NS" get secret "$SRV" "$CLI" -o json \
    | jq -c '[.items[] | {n: .metadata.name, d: .data}] | sort_by(.n)' | sha256sum | cut -d' ' -f1
}
host() { echo "pg-ha-$1.pg-ha-headless.$NS.svc.cluster.local"; }

umask 077
work=$(mktemp -d)
gentmp=$(mktemp -d)
# shellcheck disable=SC2329
cleanup() {
  rm -rf "$work" "$gentmp"
  kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "date: $(date -u +%FT%TZ)"
[ -x scripts/gen-pgbackrest-tls.sh ] || fail "scripts/gen-pgbackrest-tls.sh does not exist or is not executable"
pass "generator script is present and executable"

kubectl delete ns "$NS" --ignore-not-found --wait=true >/dev/null
kubectl create ns "$NS" >/dev/null

if ! out1=$(NS="$NS" TMPDIR="$gentmp" scripts/gen-pgbackrest-tls.sh 2>&1); then
  echo "$out1" | tail -n 5
  fail "generator failed on the first run"
fi
[ -n "$out1" ] || fail "the generator printed nothing on the first run, so the output checks would prove nothing"
[ "$(grep -c ' created$' <<<"$out1" || true)" -eq 2 ] || fail "first run must report exactly two Secrets created"
pass "first run created two Secrets"

[ "$(keys_of "$SRV")" = '["ca.crt","tls.crt","tls.key"]' ] || fail "$SRV must hold exactly ca.crt, tls.crt and tls.key"
[ "$(keys_of "$CLI")" = '["ca.crt","tls.crt","tls.key"]' ] || fail "$CLI must hold exactly ca.crt, tls.crt and tls.key"
pass "both Secrets hold exactly ca.crt, tls.crt and tls.key (no CA private key in the cluster)"

field "$SRV" ca.crt >"$work/s-ca.crt"
field "$SRV" tls.crt >"$work/s-tls.crt"
field "$SRV" tls.key >"$work/s-tls.key"
field "$CLI" ca.crt >"$work/c-ca.crt"
field "$CLI" tls.crt >"$work/c-tls.crt"
field "$CLI" tls.key >"$work/c-tls.key"
for f in s-ca.crt s-tls.crt s-tls.key c-ca.crt c-tls.crt c-tls.key; do
  [ -s "$work/$f" ] || fail "$f is empty"
done
cmp -s "$work/s-ca.crt" "$work/c-ca.crt" || fail "the two Secrets hold different CA certificates"
if cmp -s "$work/s-tls.key" "$work/c-tls.key"; then fail "server and client use the same private key"; fi
pass "six files are non-empty, one shared CA, two different private keys"

openssl verify -CAfile "$work/s-ca.crt" -purpose sslserver "$work/s-tls.crt" >/dev/null 2>&1 || fail "server certificate does not verify for server use"
openssl verify -CAfile "$work/c-ca.crt" -purpose sslclient "$work/c-tls.crt" >/dev/null 2>&1 || fail "client certificate does not verify for client use"
pass "server certificate verifies for server use and client certificate for client use"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=unrelated-ca" \
  -keyout "$work/other.key" -out "$work/other.crt" >/dev/null 2>&1
if openssl verify -CAfile "$work/other.crt" -purpose sslserver "$work/s-tls.crt" >/dev/null 2>&1; then
  fail "negative control: the server certificate verified against an unrelated CA"
fi
if openssl verify -CAfile "$work/other.crt" -purpose sslclient "$work/c-tls.crt" >/dev/null 2>&1; then
  fail "negative control: the client certificate verified against an unrelated CA"
fi
pass "negative control: an unrelated CA verifies neither certificate"

if openssl verify -CAfile "$work/s-ca.crt" -purpose sslclient "$work/s-tls.crt" >/dev/null 2>&1; then
  fail "negative control: the server certificate was accepted for client use"
fi
if openssl verify -CAfile "$work/c-ca.crt" -purpose sslserver "$work/c-tls.crt" >/dev/null 2>&1; then
  fail "negative control: the client certificate was accepted for server use"
fi
pass "negative control: each certificate is rejected for the other purpose"

names=$(openssl x509 -in "$work/s-tls.crt" -noout -ext subjectAltName | grep -o 'DNS:[^, ]*' | sed 's/^DNS://' | sort || true)
expected=$(printf '%s\n%s\n%s\n' "$(host 0)" "$(host 1)" "$(host 2)" | sort)
[ -n "$names" ] || fail "the server certificate has no DNS names"
[ "$names" = "$expected" ] || fail "server certificate names are not exactly the three pod DNS names"
for i in 0 1 2; do
  openssl verify -CAfile "$work/s-ca.crt" -purpose sslserver -verify_hostname "$(host "$i")" "$work/s-tls.crt" >/dev/null 2>&1 \
    || fail "hostname check failed for $(host "$i")"
done
if openssl verify -CAfile "$work/s-ca.crt" -purpose sslserver -verify_hostname "pg-ha-0.pg-ha-headless.other.svc.cluster.local" "$work/s-tls.crt" >/dev/null 2>&1; then
  fail "negative control: a hostname outside the certificate was accepted"
fi
pass "server certificate names exactly the three pod DNS names; a foreign hostname is rejected"

[ "$(openssl x509 -in "$work/s-tls.crt" -noout -pubkey | sha256sum)" = "$(openssl pkey -in "$work/s-tls.key" -pubout | sha256sum)" ] || fail "server key does not match server certificate"
[ "$(openssl x509 -in "$work/c-tls.crt" -noout -pubkey | sha256sum)" = "$(openssl pkey -in "$work/c-tls.key" -pubout | sha256sum)" ] || fail "client key does not match client certificate"
if [ "$(openssl x509 -in "$work/s-tls.crt" -noout -pubkey | sha256sum)" = "$(openssl pkey -in "$work/c-tls.key" -pubout | sha256sum)" ]; then
  fail "negative control: the server certificate matched the client key"
fi
pass "keys match their certificates; a mismatched pair is detected"

cn=$(openssl x509 -in "$work/c-tls.crt" -noout -subject -nameopt RFC2253 | sed 's/^subject= *//')
[ -n "$cn" ] || fail "could not read the client certificate name"
[ "$cn" = "CN=$CLIENT_CN" ] || fail "client certificate name is not CN=$CLIENT_CN"
pass "client certificate name is CN=$CLIENT_CN"

t=$(openssl x509 -in "$work/s-ca.crt" -noout -text)
[ "$(grep -F -c 'CA:TRUE' <<<"$t" || true)" -ge 1 ] || fail "ca.crt is not marked as a CA"
t=$(openssl x509 -in "$work/s-tls.crt" -noout -text)
[ "$(grep -F -c 'CA:FALSE' <<<"$t" || true)" -ge 1 ] || fail "the server certificate is marked as a CA"
t=$(openssl x509 -in "$work/c-tls.crt" -noout -text)
[ "$(grep -F -c 'CA:FALSE' <<<"$t" || true)" -ge 1 ] || fail "the client certificate is marked as a CA"
pass "ca.crt is a CA; server and client certificates are not"

for f in s-ca.crt s-tls.crt c-tls.crt; do
  openssl x509 -in "$work/$f" -noout -checkend 2592000 >/dev/null || fail "$f expires within 30 days"
done
pass "certificates are valid for more than 30 days"

[ -z "$(ls -A "$gentmp")" ] || fail "the generator left files in its temporary directory"
pass "no key material is left on disk by the generator"

cat "$work/s-tls.key" "$work/c-tls.key" >"$work/keypat"
[ -s "$work/keypat" ] || fail "the key pattern file is empty"
line=$(sed -n 2p "$work/s-tls.key")
[ -n "$line" ] || fail "could not take a key line for the leak control"
[ "$(grep -F -c -f "$work/keypat" <<<"control line with $line inside" || true)" -eq 1 ] || fail "leak control: the key scanner did not fire on a planted key line"
[ "$(grep -F -c 'PRIVATE KEY' <<<"x -----BEGIN PRIVATE KEY----- y" || true)" -eq 1 ] || fail "leak control: the marker scanner did not fire"
[ "$(grep -F -c -f "$work/keypat" <<<"$out1" || true)" -eq 0 ] || fail "key content appears in the generator output"
[ "$(grep -F -c 'PRIVATE KEY' <<<"$out1" || true)" -eq 0 ] || fail "a private key marker appears in the generator output"
pass "no key content in the generator output (both scanners fired on planted input)"

before=$(snapshot)
if ! out2=$(NS="$NS" TMPDIR="$gentmp" scripts/gen-pgbackrest-tls.sh 2>&1); then
  echo "$out2" | tail -n 5
  fail "generator failed on the second run"
fi
[ "$(grep -c 'already exists, keeping it' <<<"$out2" || true)" -eq 2 ] || fail "second run must keep both Secrets"
[ "$(snapshot)" = "$before" ] || fail "a Secret changed on the second run"
[ "$(grep -F -c -f "$work/keypat" <<<"$out2" || true)" -eq 0 ] || fail "key content appears in the second run output"
[ -z "$(ls -A "$gentmp")" ] || fail "the second run left files in the temporary directory"
pass "second run keeps both Secrets unchanged and prints no key content"
echo "ALL CHECKS PASSED"
