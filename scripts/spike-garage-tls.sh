#!/usr/bin/env bash
# ADR-0005 spike (not a test): Garage (S3 on loopback only) + nginx TLS sidecar sharing one network
# namespace, as in a pod. pgBackRest connects from another network with certificate verification ON.
# Throwaway CA and keys live in a temp dir and are deleted on exit. Secrets are redacted from the output.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. ./versions.env
umask 077

garage="garage-spike"
proxy="garage-spike-tls"
net="garage-spike-net"
host=objstore.pg-ha.svc.cluster.local
work=$(mktemp -d)
cleanup() {
  docker rm -f "$proxy" "$garage" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

ak="GK$(openssl rand -hex 12)"
sk=$(openssl rand -hex 32)
rpc=$(openssl rand -hex 32)
admin=$(openssl rand -hex 32)
redact() { sed -e "s|$ak|<key-id>|g" -e "s|$sk|<secret>|g" -e "s|$rpc|<rpc>|g" -e "s|$admin|<admin>|g"; }
step() {
  local label=$1 out
  shift
  if out=$("$@" 2>&1); then
    echo "RESULT $label OK"
  else
    echo "RESULT $label FAIL"
    echo "$out" | redact | tail -n 8
    exit 1
  fi
}
g() { docker exec "$garage" /garage "$@"; }
pg_image="${IMAGE_NAME}:${IMAGE_TAG}"

echo "date_utc: $(date -u +%FT%TZ)"
echo "garage: $OBJSTORE_IMAGE"
echo "proxy:  $OBJSTORE_TLS_PROXY_IMAGE"

# --- throwaway CA and server certificate for the Service DNS names
mkdir -p "$work/certs" "$work/ca-private" "$work/meta" "$work/data"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=spike-ca" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout "$work/ca-private/ca.key" -out "$work/certs/ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=$host" \
  -keyout "$work/certs/tls.key" -out "$work/ca-private/tls.csr" 2>/dev/null
cat >"$work/ca-private/ext.cnf" <<EXT
subjectAltName=DNS:objstore,DNS:objstore.pg-ha,DNS:objstore.pg-ha.svc,DNS:$host
extendedKeyUsage=serverAuth
keyUsage=critical,digitalSignature,keyEncipherment
basicConstraints=CA:FALSE
EXT
openssl x509 -req -in "$work/ca-private/tls.csr" -CA "$work/certs/ca.crt" -CAkey "$work/ca-private/ca.key" \
  -CAcreateserial -days 2 -extfile "$work/ca-private/ext.cnf" -out "$work/certs/tls.crt" 2>/dev/null
echo "RESULT certs OK"

# --- Garage: S3 API on loopback only (3910), admin and RPC on loopback too
cat >"$work/garage.toml" <<CONF
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "127.0.0.1:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "$rpc"

[s3_api]
s3_region = "garage"
api_bind_addr = "127.0.0.1:3910"

[admin]
api_bind_addr = "127.0.0.1:3903"
admin_token = "$admin"
CONF

# --- nginx: TLS on 3900, plain proxy to Garage on loopback. Host header is passed through unchanged (SigV4 signs it).
cat >"$work/nginx-s3.conf" <<'NGINX'
server {
  listen 3900 ssl;
  ssl_certificate     /etc/nginx/tls/tls.crt;
  ssl_certificate_key /etc/nginx/tls/tls.key;
  ssl_protocols       TLSv1.2 TLSv1.3;
  client_max_body_size 0;
  location / {
    proxy_pass http://127.0.0.1:3910;
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_request_buffering off;
    proxy_max_temp_file_size 0;
  }
}
NGINX

# nginx runs as uid 101 inside its container: let it read the throwaway files and directories.
chmod 755 "$work" "$work/certs"
chmod 644 "$work/certs/"* "$work/nginx-s3.conf"

docker network create "$net" >/dev/null
docker run -d --name "$garage" --network "$net" --network-alias "$host" --user "$(id -u):$(id -g)" \
  -v "$work/garage.toml:/etc/garage.toml:ro" \
  -v "$work/meta:/var/lib/garage/meta" -v "$work/data:/var/lib/garage/data" \
  "$OBJSTORE_IMAGE" >/dev/null

up=no
for _ in $(seq 1 30); do
  if g status >/dev/null 2>&1; then up=yes; break; fi
  sleep 1
done
if [ "$up" != yes ]; then
  echo "RESULT garage-start FAIL"
  docker logs "$garage" 2>&1 | redact | tail -n 20
  exit 1
fi
echo "RESULT garage-start OK"

id=$(g status 2>/dev/null | grep -oE '[0-9a-f]{16}' | sed -n '1p')
[ -n "$id" ] || { echo "RESULT node-id FAIL"; exit 1; }
step layout-assign g layout assign -z dc1 -c 1GB "$id"
step layout-apply g layout apply --version 1
step bucket-create g bucket create pgbackrest
step key-import g key import --yes -n spike "$ak" "$sk"
step bucket-allow g bucket allow --read --write --owner pgbackrest --key "$ak"

docker run -d --name "$proxy" --network "container:$garage" --user 101:101 \
  --cap-drop ALL --security-opt no-new-privileges \
  -v "$work/nginx-s3.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$work/certs:/etc/nginx/tls:ro" \
  "$OBJSTORE_TLS_PROXY_IMAGE" >/dev/null

probe_port() {
  docker run --rm --network "$net" --entrypoint python3 "$pg_image" -c '
import socket, sys
s = socket.socket()
s.settimeout(3)
try:
    s.connect((sys.argv[1], int(sys.argv[2])))
    print("open")
except Exception as e:
    print("closed", type(e).__name__)
' "$host" "$1" 2>&1 | tail -n 1
}

proxy_up=no
for _ in $(seq 1 20); do
  if [ "$(probe_port 3900 | cut -d' ' -f1)" = open ]; then proxy_up=yes; break; fi
  sleep 1
done
if [ "$proxy_up" != yes ]; then
  echo "RESULT proxy-start FAIL"
  docker logs "$proxy" 2>&1 | redact | tail -n 20
  exit 1
fi
echo "RESULT proxy-start OK"

echo "--- reachability from another container on the network"
echo "port 3900 (TLS front): $(probe_port 3900)"
echo "port 3910 (Garage S3, loopback only): $(probe_port 3910)"
echo "port 3903 (admin, loopback only): $(probe_port 3903)"
echo "port 3901 (RPC, loopback only): $(probe_port 3901)"

cat >"$work/pgbr.env" <<ENVF
PGBACKREST_STANZA=spike${RANDOM}
PGBACKREST_PG1_PATH=/tmp/pgdata
PGBACKREST_LOG_LEVEL_CONSOLE=warn
PGBACKREST_LOG_LEVEL_FILE=off
PGBACKREST_REPO1_TYPE=s3
PGBACKREST_REPO1_PATH=/spike
PGBACKREST_REPO1_S3_BUCKET=pgbackrest
PGBACKREST_REPO1_S3_ENDPOINT=$host
PGBACKREST_REPO1_STORAGE_PORT=3900
PGBACKREST_REPO1_S3_REGION=garage
PGBACKREST_REPO1_S3_URI_STYLE=path
PGBACKREST_REPO1_S3_KEY=$ak
PGBACKREST_REPO1_S3_KEY_SECRET=$sk
ENVF

echo "--- negative control: verification on, CA file NOT provided (must fail)"
rc=0
out=$(timeout 180 docker run --rm --network "$net" --env-file "$work/pgbr.env" \
  --entrypoint pgbackrest "$pg_image" repo-ls backup </dev/null 2>&1) || rc=$?
echo "$out" | redact | tail -n 3
if [ "$rc" -ne 0 ]; then echo "RESULT negative-control OK (failed as expected, rc=$rc)"; else echo "RESULT negative-control FAIL (succeeded without the CA)"; fi

echo "--- round trip: verification on, CA file provided"
rc=0
# shellcheck disable=SC2016
out=$(docker run --rm --network "$net" --env-file "$work/pgbr.env" \
  -e PGBACKREST_REPO1_STORAGE_CA_FILE=/certs/ca.crt -v "$work/certs/ca.crt:/certs/ca.crt:ro" \
  --entrypoint sh "$pg_image" -c '
set -u
step_fail() { echo "STEP=$1 RESULT=FAIL"; exit 1; }
mkdir -p /tmp/pgdata
initdb -D /tmp/pgdata >/dev/null 2>&1 || step_fail initdb
echo "STEP=initdb RESULT=OK"
pgbackrest --no-online stanza-create || step_fail stanza-create
echo "STEP=stanza-create RESULT=OK"
listing=$(pgbackrest repo-ls "backup/$PGBACKREST_STANZA" </dev/null) || step_fail ls
case "$listing" in *backup.info*) echo "STEP=ls RESULT=OK" ;; *) step_fail ls ;; esac
got=$(pgbackrest repo-get "backup/$PGBACKREST_STANZA/backup.info" </dev/null) || step_fail get
case "$got" in *"[backrest]"*) echo "STEP=get RESULT=OK" ;; *) step_fail get ;; esac
pgbackrest stop || step_fail stop
pgbackrest stanza-delete || step_fail stanza-delete
echo "STEP=stanza-delete RESULT=OK"
after=$(pgbackrest repo-ls backup </dev/null) || step_fail cleanup
case "$after" in *"$PGBACKREST_STANZA"*) step_fail cleanup ;; *) echo "STEP=cleanup RESULT=OK" ;; esac
' 2>&1) || rc=$?
echo "$out" | redact
echo "RESULT roundtrip-verified-tls rc=$rc"
if [ "$rc" -ne 0 ]; then
  echo "--- proxy log (tail)"
  docker logs "$proxy" 2>&1 | redact | tail -n 15
fi
echo "SPIKE DONE"
