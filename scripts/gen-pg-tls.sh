#!/usr/bin/env bash
# Generate the PostgreSQL TLS Secret pg-tls once (ca.crt, tls.crt, tls.key). Never printed, never committed.
# An existing Secret is kept, so a rerun rotates nothing.
# The CA private key exists only in a temporary directory while the server certificate is signed and is removed
# with rm before the Secret is written (rm is not a secure erase, see docs/known-limitations.md).
set -euo pipefail
NS="${NS:-pg-ha}"
DAYS=825
umask 077

if kubectl -n "$NS" get secret pg-tls >/dev/null 2>&1; then
  echo "secret pg-tls already exists, keeping it"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/ca"
openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" -subj "/CN=pg-ha-ca" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout "$work/ca/ca.key" -out "$work/ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=pg-primary.$NS.svc.cluster.local" \
  -keyout "$work/tls.key" -out "$work/tls.csr" 2>/dev/null
{
  echo "subjectAltName=DNS:localhost,IP:127.0.0.1,DNS:pg-primary,DNS:pg-primary.$NS,DNS:pg-primary.$NS.svc,DNS:pg-primary.$NS.svc.cluster.local,DNS:pg-replica,DNS:pg-replica.$NS,DNS:pg-replica.$NS.svc,DNS:pg-replica.$NS.svc.cluster.local,DNS:pg-ha-headless.$NS.svc.cluster.local,$(for i in 0 1 2; do printf 'DNS:pg-ha-%s.pg-ha-headless,DNS:pg-ha-%s.pg-ha-headless.%s,DNS:pg-ha-%s.pg-ha-headless.%s.svc,DNS:pg-ha-%s.pg-ha-headless.%s.svc.cluster.local,' "$i" "$i" "$NS" "$i" "$NS" "$i" "$NS"; done | sed 's/,$//')"
  echo "extendedKeyUsage=serverAuth"
  echo "keyUsage=critical,digitalSignature,keyEncipherment"
  echo "basicConstraints=CA:FALSE"
} > "$work/ext.cnf"
openssl x509 -req -in "$work/tls.csr" -CA "$work/ca.crt" -CAkey "$work/ca/ca.key" -CAcreateserial \
  -days "$DAYS" -extfile "$work/ext.cnf" -out "$work/tls.crt" 2>/dev/null
rm -rf "$work/ca"
kubectl -n "$NS" create secret generic pg-tls \
  --from-file=ca.crt="$work/ca.crt" --from-file=tls.crt="$work/tls.crt" --from-file=tls.key="$work/tls.key" \
  --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
rm -rf "$work"
trap - EXIT
echo "secret pg-tls created"
