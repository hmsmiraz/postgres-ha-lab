#!/usr/bin/env bash
# ADR-0005 spike 2 (not a test): Garage with S3, admin and RPC on loopback only; nginx TLS sidecar on
# 3900 (S3) and 3903 (admin). scripts/objstore-init.py initialises Garage through the admin API over verified
# TLS from another container: twice (repeatable), once with a wrong token, then a pgBackRest round trip
# with the key it created. Throwaway CA and secrets live in a temp dir. Secrets are redacted from the output.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. ./versions.env
umask 077

garage="garage-spike"
proxy="garage-spike-tls"
net="garage-spike-net"
host="objstore.pg-ha.svc.cluster.local"
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
bad=$(openssl rand -hex 32)
redact() { sed -e "s|$ak|<key-id>|g" -e "s|$sk|<secret>|g" -e "s|$rpc|<rpc>|g" -e "s|$admin|<admin>|g" -e "s|$bad|<bad-token>|g"; }
g() { docker exec "$garage" /garage "$@"; }
pg_image="${IMAGE_NAME}:${IMAGE_TAG}"

echo "date_utc: $(date -u +%FT%TZ)"
echo "garage: $OBJSTORE_IMAGE"
echo "proxy:  $OBJSTORE_TLS_PROXY_IMAGE"

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
api_bind_addr = "127.0.0.1:3913"
admin_token = "$admin"
CONF

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
server {
  listen 3903 ssl;
  ssl_certificate     /etc/nginx/tls/tls.crt;
  ssl_certificate_key /etc/nginx/tls/tls.key;
  ssl_protocols       TLSv1.2 TLSv1.3;
  location / {
    proxy_pass http://127.0.0.1:3913;
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
  }
}
NGINX

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
  if [ "$(probe_port 3900 | cut -d' ' -f1)" = open ] && [ "$(probe_port 3903 | cut -d' ' -f1)" = open ]; then proxy_up=yes; break; fi
  sleep 1
done
if [ "$proxy_up" != yes ]; then
  echo "RESULT proxy-start FAIL"
  docker logs "$proxy" 2>&1 | redact | tail -n 20
  exit 1
fi
echo "RESULT proxy-start OK"

echo "--- reachability from another container on the network"
echo "port 3900 (S3 over TLS): $(probe_port 3900)"
echo "port 3903 (admin over TLS): $(probe_port 3903)"
echo "port 3910 (S3 loopback): $(probe_port 3910)"
echo "port 3913 (admin loopback): $(probe_port 3913)"
echo "port 3901 (RPC loopback): $(probe_port 3901)"

run_init() {
  local label=$1 token=$2 rc=0 out
  cat >"$work/init.env" <<ENVF
OBJSTORE_ADMIN_URL=https://$host:3903
OBJSTORE_CA_FILE=/certs/ca.crt
ADMIN_TOKEN=$token
ACCESS_KEY_ID=$ak
SECRET_ACCESS_KEY=$sk
ENVF
  out=$(docker run --rm --network "$net" --env-file "$work/init.env" \
    -v "$work/certs/ca.crt:/certs/ca.crt:ro" -v "$PWD/scripts/objstore-init.py:/init/objstore-init.py:ro" \
    --entrypoint python3 "$pg_image" /init/objstore-init.py 2>&1) || rc=$?
  echo "--- init run: $label"
  echo "$out" | redact
  echo "RESULT init-$label rc=$rc"
}

run_init first "$admin"
run_init second "$admin"

echo "--- what Garage holds after two runs (must be one bucket and one key)"
g bucket list 2>&1 | redact || true
g key list 2>&1 | redact || true

run_init wrong-token "$bad"

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

echo "--- pgBackRest round trip with the key created by the init script (read+write only), verification on"
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
echo "RESULT roundtrip-init-key rc=$rc"
echo "SPIKE DONE"
