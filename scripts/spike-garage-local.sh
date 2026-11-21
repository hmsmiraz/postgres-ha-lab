#!/usr/bin/env bash
# ADR-0004 spike (not a test): run Garage in plain Docker, no cluster. Answers three questions:
#  1. does the CLI setup flow work (layout, bucket, key, allow)?
#  2. does pgBackRest accept this plain-HTTP S3 endpoint (the HTTPS risk in ADR-0004)?
#  3. can the pg-ha image drive the Garage admin API, given that the Garage image has no shell?
# Secrets are random and never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. ./versions.env
umask 077

name=garage-spike
work=$(mktemp -d)
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
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
g() { docker exec "$name" /garage "$@"; }

echo "date_utc: $(date -u +%FT%TZ)"
echo "image: $OBJSTORE_IMAGE"

mkdir -p "$work/meta" "$work/data"
cat >"$work/garage.toml" <<CONF
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "0.0.0.0:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "$rpc"

[s3_api]
s3_region = "garage"
api_bind_addr = "0.0.0.0:3900"

[admin]
api_bind_addr = "0.0.0.0:3903"
admin_token = "$admin"
CONF

echo "--- pg-ha image: python3?"
docker run --rm --entrypoint sh "${IMAGE_NAME}:${IMAGE_TAG}" -c 'command -v python3 && python3 --version' 2>&1 \
  || echo "RESULT python3 MISSING"

docker run -d --name "$name" --user "$(id -u):$(id -g)" \
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
  docker logs "$name" 2>&1 | redact | tail -n 20
  exit 1
fi
echo "RESULT garage-start OK"

g status
id=$(g status | grep -oE '[0-9a-f]{16}' | sed -n '1p')
[ -n "$id" ] || { echo "RESULT node-id FAIL (none found in status output)"; exit 1; }
echo "RESULT node-id OK"

step layout-assign g layout assign -z dc1 -c 1GB "$id"
step layout-apply g layout apply --version 1
step bucket-create g bucket create pgbackrest
if out=$(g key import --yes -n spike "$ak" "$sk" 2>&1); then
  echo "RESULT key-import OK"
else
  echo "RESULT key-import FAIL"
  echo "$out" | redact | tail -n 5
  exit 1
fi
step bucket-allow g bucket allow --read --write --owner pgbackrest --key "$ak"

echo "--- admin API from the pg-ha image (python3, plain HTTP, token not printed)"
printf 'ADMIN_TOKEN=%s\n' "$admin" >"$work/admin.env"
# shellcheck disable=SC2016
if out=$(docker run --rm --network "container:$name" --env-file "$work/admin.env" \
  --entrypoint python3 "${IMAGE_NAME}:${IMAGE_TAG}" -c '
import json, os, urllib.request
req = urllib.request.Request("http://127.0.0.1:3903/v2/GetClusterStatus", headers={"Authorization": "Bearer " + os.environ["ADMIN_TOKEN"]})
r = urllib.request.urlopen(req, timeout=10)
d = json.load(r)
print("http", r.status, "top-level keys:", sorted(d.keys()))
' 2>&1); then
  echo "RESULT admin-api OK"
  echo "$out" | redact
else
  echo "RESULT admin-api FAIL"
  echo "$out" | redact | tail -n 8
fi

echo "--- pgBackRest against plain-HTTP Garage"
cat >"$work/pgbr.env" <<ENVF
PGBACKREST_STANZA=spike${RANDOM}
PGBACKREST_PG1_PATH=/tmp/pgdata
PGBACKREST_LOG_LEVEL_CONSOLE=warn
PGBACKREST_LOG_LEVEL_FILE=off
PGBACKREST_REPO1_TYPE=s3
PGBACKREST_REPO1_PATH=/spike
PGBACKREST_REPO1_S3_BUCKET=pgbackrest
PGBACKREST_REPO1_S3_ENDPOINT=127.0.0.1
PGBACKREST_REPO1_STORAGE_PORT=3900
PGBACKREST_REPO1_S3_REGION=garage
PGBACKREST_REPO1_S3_URI_STYLE=path
PGBACKREST_REPO1_STORAGE_VERIFY_TLS=n
PGBACKREST_REPO1_S3_KEY=$ak
PGBACKREST_REPO1_S3_KEY_SECRET=$sk
ENVF
rc=0
# shellcheck disable=SC2016
out=$(docker run --rm --network "container:$name" --env-file "$work/pgbr.env" \
  --entrypoint sh "${IMAGE_NAME}:${IMAGE_TAG}" -c '
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
echo "RESULT pgbackrest-roundtrip rc=$rc"
echo "SPIKE DONE"
