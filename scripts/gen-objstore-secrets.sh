#!/usr/bin/env bash
# Generate the object store Secrets once: objstore-credentials, objstore-admin, objstore-tls.
# Never printed, never committed. An existing Secret is kept, so a rerun rotates nothing.
# The TLS CA private key exists only in a temporary directory while the server certificate is signed and is removed
# before the Secret is written: the cluster only holds the CA certificate, the server certificate and its key.
# (rm is not a secure erase. See docs/known-limitations.md.)
set -euo pipefail
NS="${NS:-pg-ha}"
SVC=objstore
DAYS=825
umask 077

exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }
hex() { openssl rand -hex "$1"; }

if exists objstore-credentials; then
  echo "secret objstore-credentials already exists, keeping it"
else
  kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: objstore-credentials
type: Opaque
stringData:
  access-key-id: "GK$(hex 12)"
  secret-access-key: "$(hex 32)"
YAML
  echo "secret objstore-credentials created"
fi

if exists objstore-admin; then
  echo "secret objstore-admin already exists, keeping it"
else
  kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: objstore-admin
type: Opaque
stringData:
  admin-token: "$(hex 32)"
  rpc-secret: "$(hex 32)"
YAML
  echo "secret objstore-admin created"
fi

if exists objstore-tls; then
  echo "secret objstore-tls already exists, keeping it"
else
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  mkdir "$work/ca"
  openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" -subj "/CN=objstore-ca" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$work/ca/ca.key" -out "$work/ca.crt" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$SVC.$NS.svc.cluster.local" \
    -keyout "$work/tls.key" -out "$work/tls.csr" 2>/dev/null
  cat >"$work/ext.cnf" <<EXT
subjectAltName=DNS:$SVC,DNS:$SVC.$NS,DNS:$SVC.$NS.svc,DNS:$SVC.$NS.svc.cluster.local
extendedKeyUsage=serverAuth
keyUsage=critical,digitalSignature,keyEncipherment
basicConstraints=CA:FALSE
EXT
  openssl x509 -req -in "$work/tls.csr" -CA "$work/ca.crt" -CAkey "$work/ca/ca.key" -CAcreateserial \
    -days "$DAYS" -extfile "$work/ext.cnf" -out "$work/tls.crt" 2>/dev/null
  rm -rf "$work/ca"
  kubectl -n "$NS" create secret generic objstore-tls \
    --from-file=ca.crt="$work/ca.crt" --from-file=tls.crt="$work/tls.crt" --from-file=tls.key="$work/tls.key" \
    --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
  rm -rf "$work"
  trap - EXIT
  echo "secret objstore-tls created"
fi
