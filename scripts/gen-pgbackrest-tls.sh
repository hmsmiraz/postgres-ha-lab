#!/usr/bin/env bash
# Generate the TLS material for pgBackRest server mode (ADR-0002) once: Secrets pgbackrest-tls-server and
# pgbackrest-tls-client, each holding exactly ca.crt, tls.crt and tls.key. Never printed, never committed.
# The CA private key exists only in a temporary directory while the two certificates are signed and is removed before
# the Secrets are written, so the cluster holds no CA private key. (rm is not a secure erase.)
# The server certificate names the three pod DNS names behind pg-ha-headless and is valid for server use only.
# The client certificate is CN=pgbackrest-backup and is valid for client use only.
# An existing pair is kept, so a rerun rotates nothing. If only one of the two exists the script stops.
set -euo pipefail
NS="${NS:-pg-ha}"
HEADLESS=pg-ha-headless
DAYS=825
SRV=pgbackrest-tls-server
CLI=pgbackrest-tls-client
umask 077

exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }

if exists "$SRV" && exists "$CLI"; then
  echo "secret $SRV already exists, keeping it"
  echo "secret $CLI already exists, keeping it"
  exit 0
fi
if exists "$SRV" || exists "$CLI"; then
  echo "only one of $SRV and $CLI exists; delete both Secrets to regenerate them together" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/ca"
openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" -subj "/CN=pgbackrest-ca" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout "$work/ca/ca.key" -out "$work/ca.crt" 2>/dev/null

openssl req -newkey rsa:2048 -nodes -subj "/CN=pgbackrest-server" \
  -keyout "$work/server.key" -out "$work/server.csr" 2>/dev/null
san=""
for i in 0 1 2; do
  san="${san}${san:+,}DNS:pg-ha-$i.$HEADLESS.$NS.svc.cluster.local"
done
cat >"$work/server.ext" <<EXT
subjectAltName=$san
extendedKeyUsage=serverAuth
keyUsage=critical,digitalSignature,keyEncipherment
basicConstraints=CA:FALSE
EXT
openssl x509 -req -in "$work/server.csr" -CA "$work/ca.crt" -CAkey "$work/ca/ca.key" -CAcreateserial \
  -days "$DAYS" -extfile "$work/server.ext" -out "$work/server.crt" 2>/dev/null

openssl req -newkey rsa:2048 -nodes -subj "/CN=pgbackrest-backup" \
  -keyout "$work/client.key" -out "$work/client.csr" 2>/dev/null
cat >"$work/client.ext" <<EXT
extendedKeyUsage=clientAuth
keyUsage=critical,digitalSignature,keyEncipherment
basicConstraints=CA:FALSE
EXT
openssl x509 -req -in "$work/client.csr" -CA "$work/ca.crt" -CAkey "$work/ca/ca.key" -CAcreateserial \
  -days "$DAYS" -extfile "$work/client.ext" -out "$work/client.crt" 2>/dev/null
rm -rf "$work/ca"

kubectl -n "$NS" create secret generic "$SRV" \
  --from-file=ca.crt="$work/ca.crt" --from-file=tls.crt="$work/server.crt" --from-file=tls.key="$work/server.key" \
  --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
echo "secret $SRV created"
kubectl -n "$NS" create secret generic "$CLI" \
  --from-file=ca.crt="$work/ca.crt" --from-file=tls.crt="$work/client.crt" --from-file=tls.key="$work/client.key" \
  --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
echo "secret $CLI created"
rm -rf "$work"
trap - EXIT
