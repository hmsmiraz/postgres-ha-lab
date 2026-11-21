#!/usr/bin/env bash
# Verification spike (not a test). Answers what the earlier spikes left open:
#  1. Garage reads rpc_secret and the admin token from environment variables (nothing secret in garage.toml)
#  2. pgBackRest rejects a certificate whose names do not match the host it connected to
#  3. a ~100 MB offline backup goes through the TLS front
#  4. layout, bucket, key and data survive recreating the containers (init reports "already ...")
# Throwaway CA and secrets live in a temp dir. Secrets are redacted from the output.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. ./versions.env
umask 077

garage="garage-spike"
proxy="garage-spike-tls"
net="garage-spike-net"
host="objstore.pg-ha.svc.cluster.local"
stanza="verify${RANDOM}"
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
pg_image="${IMAGE_NAME}:${IMAGE_TAG}"
g() { docker exec "$garage" /garage "$@"; }

echo "date_utc: $(date -u +%FT%TZ)"
echo "garage: $OBJSTORE_IMAGE"
echo "proxy:  $OBJSTORE_TLS_PROXY_IMAGE"

# --- throwaway CA and server certificate
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

# --- Garage config WITHOUT secrets, secrets only in an env file
cat >"$work/garage.toml" <<'CONF'
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "127.0.0.1:3901"
rpc_public_addr = "127.0.0.1:3901"

[s3_api]
s3_region = "garage"
api_bind_addr = "127.0.0.1:3910"

[admin]
api_bind_addr = "127.0.0.1:3913"
CONF
cat >"$work/garage.env" <<ENVF
GARAGE_RPC_SECRET=$rpc
GARAGE_ADMIN_TOKEN=$admin
ENVF
if grep -q -E 'rpc_secret|admin_token' "$work/garage.toml"; then
  echo "RESULT secrets-not-in-config FAIL"
  exit 1
fi
echo "RESULT secrets-not-in-config OK (garage.toml holds neither secret; both come from environment variables)"

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

cat >"$work/pgbr.env" <<ENVF
PGBACKREST_STANZA=$stanza
PGBACKREST_PG1_PATH=/tmp/pgdata
PGBACKREST_LOG_LEVEL_CONSOLE=warn
PGBACKREST_LOG_LEVEL_FILE=off
PGBACKREST_REPO1_TYPE=s3
PGBACKREST_REPO1_PATH=/verify
PGBACKREST_REPO1_S3_BUCKET=pgbackrest
PGBACKREST_REPO1_S3_ENDPOINT=$host
PGBACKREST_REPO1_STORAGE_PORT=3900
PGBACKREST_REPO1_S3_REGION=garage
PGBACKREST_REPO1_S3_URI_STYLE=path
PGBACKREST_REPO1_STORAGE_CA_FILE=/certs/ca.crt
PGBACKREST_REPO1_S3_KEY=$ak
PGBACKREST_REPO1_S3_KEY_SECRET=$sk
ENVF

probe_port() {
  docker run --rm --network "$net" --entrypoint python3 "$pg_image" -c '
import socket, sys
s = socket.socket()
s.settimeout(3)
try:
    s.connect((sys.argv[1], int(sys.argv[2])))
    print("open")
except Exception:
    print("closed")
' "$host" "$1" 2>&1 | tail -n 1
}

start_stack() {
  docker rm -f "$proxy" "$garage" >/dev/null 2>&1 || true
  docker run -d --name "$garage" --network "$net" --network-alias "$host" --user "$(id -u):$(id -g)" \
    --env-file "$work/garage.env" -v "$work/garage.toml:/etc/garage.toml:ro" \
    -v "$work/meta:/var/lib/garage/meta" -v "$work/data:/var/lib/garage/data" \
    "$OBJSTORE_IMAGE" >/dev/null
  local up=no
  for _ in $(seq 1 30); do
    if g status >/dev/null 2>&1; then up=yes; break; fi
    sleep 1
  done
  if [ "$up" != yes ]; then
    echo "RESULT garage-start FAIL (Garage did not come up with secrets from environment variables)"
    docker logs "$garage" 2>&1 | redact | tail -n 20
    exit 1
  fi
  echo "RESULT garage-start OK"
  docker run -d --name "$proxy" --network "container:$garage" --user 101:101 \
    --cap-drop ALL --security-opt no-new-privileges \
    -v "$work/nginx-s3.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$work/certs:/etc/nginx/tls:ro" \
    "$OBJSTORE_TLS_PROXY_IMAGE" >/dev/null
  local ok=no
  for _ in $(seq 1 20); do
    if [ "$(probe_port 3900)" = open ] && [ "$(probe_port 3903)" = open ]; then ok=yes; break; fi
    sleep 1
  done
  if [ "$ok" != yes ]; then
    echo "RESULT proxy-start FAIL"
    docker logs "$proxy" 2>&1 | redact | tail -n 20
    exit 1
  fi
  echo "RESULT proxy-start OK"
}

run_init() {
  local label=$1 token=$2
  cat >"$work/init.env" <<ENVF
OBJSTORE_ADMIN_URL=https://$host:3903
OBJSTORE_CA_FILE=/certs/ca.crt
ADMIN_TOKEN=$token
ACCESS_KEY_ID=$ak
SECRET_ACCESS_KEY=$sk
ENVF
  init_rc=0
  init_out=$(docker run --rm --network "$net" --env-file "$work/init.env" \
    -v "$work/certs/ca.crt:/certs/ca.crt:ro" -v "$PWD/scripts/objstore-init.py:/init/objstore-init.py:ro" \
    --entrypoint python3 "$pg_image" /init/objstore-init.py 2>&1) || init_rc=$?
  echo "--- init run: $label"
  echo "$init_out" | redact
  echo "RESULT init-$label rc=$init_rc"
}

pg_run() {
  docker run --rm --network "$net" --env-file "$work/pgbr.env" -v "$work/certs/ca.crt:/certs/ca.crt:ro" \
    --entrypoint sh "$pg_image" -c "$1" 2>&1
}

docker network create "$net" >/dev/null
start_stack

run_init first "$admin"
case "$init_out" in *"INIT OK"*) echo "RESULT init-first-check OK (admin token from the environment variable works)" ;; *) echo "RESULT init-first-check FAIL" ;; esac
run_init wrong-token "$bad"
if [ "$init_rc" -ne 0 ]; then echo "RESULT token-enforced OK (wrong token rejected)"; else echo "RESULT token-enforced FAIL (wrong token accepted)"; fi

echo "--- hostname mismatch: connect to the container IP, which is not in the certificate names, with the right CA"
ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$garage")
sed "s|^PGBACKREST_REPO1_S3_ENDPOINT=.*|PGBACKREST_REPO1_S3_ENDPOINT=$ip|" "$work/pgbr.env" >"$work/pgbr-ip.env"
rc=0
out=$(docker run --rm --network "$net" --env-file "$work/pgbr-ip.env" -v "$work/certs/ca.crt:/certs/ca.crt:ro" \
  --entrypoint pgbackrest "$pg_image" repo-ls backup </dev/null 2>&1) || rc=$?
echo "$out" | redact | tail -n 3
case "$out" in *certificate*) mentions=yes ;; *) mentions=no ;; esac
if [ "$rc" -ne 0 ] && [ "$mentions" = yes ]; then
  echo "RESULT hostname-mismatch OK (rejected with a certificate error, rc=$rc)"
else
  echo "RESULT hostname-mismatch FAIL (rc=$rc, certificate error mentioned: $mentions)"
fi

echo "--- offline backup of an initdb directory plus a 100 MB random file, through the TLS front"
rc=0
t0=$(date +%s)
out=$(pg_run '
set -u
mkdir -p /tmp/pgdata
initdb -D /tmp/pgdata >/dev/null 2>&1 || { echo "STEP=initdb RESULT=FAIL"; exit 1; }
dd if=/dev/urandom of=/tmp/pgdata/bigfile bs=1M count=100 status=none || { echo "STEP=bigfile RESULT=FAIL"; exit 1; }
pgbackrest --no-online stanza-create || { echo "STEP=stanza-create RESULT=FAIL"; exit 1; }
echo "STEP=stanza-create RESULT=OK"
pgbackrest --no-online backup --type=full || { echo "STEP=backup RESULT=FAIL"; exit 1; }
echo "STEP=backup RESULT=OK"
pgbackrest info
') || rc=$?
t1=$(date +%s)
echo "$out" | redact | tail -n 16
case "$out" in *"STEP=backup RESULT=OK"*) backup_ok=yes ;; *) backup_ok=no ;; esac
if [ "$rc" -eq 0 ] && [ "$backup_ok" = yes ]; then
  echo "RESULT backup-large OK (elapsed $((t1 - t0)) s)"
else
  echo "RESULT backup-large FAIL (rc=$rc, elapsed $((t1 - t0)) s)"
fi
echo "--- Garage view of the bucket"
g bucket info pgbackrest 2>&1 | redact | tail -n 12 || true

echo "--- recreate both containers on the same data directories"
start_stack
run_init after-restart "$admin"
if [ "$init_rc" -eq 0 ] \
   && [[ "$init_out" == *"layout: role already assigned"* ]] \
   && [[ "$init_out" == *"bucket: already exists"* ]] \
   && [[ "$init_out" == *"key: already imported"* ]]; then
  echo "RESULT restart-init OK (layout, bucket and key persisted)"
else
  echo "RESULT restart-init FAIL"
fi
echo "--- repository after the restart (the stanza and the backup must still be there)"
out=$(pg_run 'pgbackrest info </dev/null') || true
echo "$out" | redact | tail -n 12
case "$out" in *"full backup"*) echo "RESULT restart-data OK (backup still listed)" ;; *) echo "RESULT restart-data FAIL" ;; esac
echo "VERIFY DONE"
