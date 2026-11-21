#!/usr/bin/env bash
# Static checks for k8s/objstore/*.yaml. Nothing is created in the cluster: dry runs are server-side.
# Every check asserts its own input, so an empty extraction cannot pass. (The first version ran nginx -t against an
# empty file because of a kubectl error and printed "syntax is ok".)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. ./versions.env

fail=0
pass() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
gname="objstore-static-garage"
r=$(mktemp -d)
chmod 777 "$r"
# shellcheck disable=SC2329
cleanup() {
  docker rm -f "$gname" >/dev/null 2>&1 || true
  rm -rf "$r"
}
trap cleanup EXIT

echo "date_utc: $(date -u +%FT%TZ)"

sed -e "s|__GARAGE_IMAGE__|${OBJSTORE_IMAGE}|g" -e "s|__PROXY_IMAGE__|${OBJSTORE_TLS_PROXY_IMAGE}|g" k8s/objstore/30-statefulset.yaml >"$r/30.yaml"
sed "s|__IMAGE__|${IMAGE_NAME}:${IMAGE_TAG}|g" k8s/objstore/40-init-job.yaml >"$r/40.yaml"
cp k8s/objstore/10-config.yaml k8s/objstore/20-service.yaml "$r/"

n=$(cat "$r/10-config.yaml" "$r/20-service.yaml" "$r/30.yaml" "$r/40.yaml" | grep -c '__' || true)
if [ "$n" -eq 0 ]; then pass "no unreplaced placeholders"; else bad "$n unreplaced placeholders"; fi

if kubeconform -strict -summary "$r/10-config.yaml" "$r/20-service.yaml" "$r/30.yaml" "$r/40.yaml" >"$r/kc.txt" 2>&1; then
  pass "kubeconform: $(tail -n 1 "$r/kc.txt")"
else
  bad "kubeconform: $(tail -n 3 "$r/kc.txt")"
fi

# --- extract the two configs from the ConfigMap, and assert what was extracted
kubectl create --dry-run=client -f "$r/10-config.yaml" -o json >"$r/cm.json" 2>"$r/cm.err" || true
jq -r '.data["nginx-s3.conf"] // empty' "$r/cm.json" >"$r/default.conf" 2>/dev/null || true
jq -r '.data["garage.toml"] // empty' "$r/cm.json" >"$r/garage.toml" 2>/dev/null || true
if grep -q 'listen 3900 ssl' "$r/default.conf" && grep -q 'listen 3903 ssl' "$r/default.conf"; then
  pass "nginx config extracted ($(wc -l <"$r/default.conf") lines, both TLS listeners present)"
else
  bad "nginx config extraction is empty or incomplete ($(head -c 200 "$r/cm.err"))"
fi
if grep -q 'rpc_bind_addr = "127.0.0.1:3901"' "$r/garage.toml" && grep -q 'api_bind_addr = "127.0.0.1:3910"' "$r/garage.toml" \
   && grep -q 'api_bind_addr = "127.0.0.1:3913"' "$r/garage.toml"; then
  pass "garage.toml extracted, S3, admin and RPC all bind to loopback"
else
  bad "garage.toml extraction is empty or a bind address is not loopback"
fi
if grep -q -E 'rpc_secret|admin_token' "$r/garage.toml"; then bad "garage.toml contains a secret key name"; else pass "garage.toml holds no secret"; fi

# --- nginx: load the real config, plus a control with an empty config
mkdir "$r/tls"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=t" -keyout "$r/tls/tls.key" -out "$r/tls/tls.crt" 2>/dev/null
chmod 644 "$r/tls/"*
: >"$r/empty.conf"
chmod 644 "$r/default.conf" "$r/empty.conf"
if out=$(docker run --rm --user 101:101 -v "$r/default.conf:/etc/nginx/conf.d/default.conf:ro" -v "$r/tls:/etc/nginx/tls:ro" \
    "$OBJSTORE_TLS_PROXY_IMAGE" nginx -T 2>&1); then
  if grep -q 'test is successful' <<<"$out" && grep -q 'listen 3900 ssl' <<<"$out" && grep -q 'listen 3903 ssl' <<<"$out"; then
    pass "nginx -T loads the ConfigMap config: both TLS server blocks appear in the loaded configuration"
  else
    bad "nginx -T ran, but our server blocks are not in the loaded configuration"
  fi
else
  bad "nginx -T failed: $(tail -n 3 <<<"$out")"
fi
out=$(docker run --rm --user 101:101 -v "$r/empty.conf:/etc/nginx/conf.d/default.conf:ro" -v "$r/tls:/etc/nginx/tls:ro" \
    "$OBJSTORE_TLS_PROXY_IMAGE" nginx -T 2>&1 || true)
if grep -q 'listen 3900' <<<"$out"; then
  bad "control: with an empty config the check still sees a 3900 listener, so the nginx check proves nothing"
else
  pass "control: with an empty config the check finds no 3900 listener (the nginx check discriminates)"
fi

# --- Garage: start it with the ConfigMap config and secrets from the environment, then run the probe command
mkdir -p "$r/gdata/meta" "$r/gdata/data"
chmod -R 777 "$r/gdata"
chmod 644 "$r/garage.toml"
docker rm -f "$gname" >/dev/null 2>&1 || true
docker run -d --name "$gname" --user "$(id -u):$(id -g)" \
  -e GARAGE_RPC_SECRET="$(openssl rand -hex 32)" -e GARAGE_ADMIN_TOKEN="$(openssl rand -hex 32)" \
  -v "$r/garage.toml:/etc/garage.toml:ro" -v "$r/gdata:/var/lib/garage" "$OBJSTORE_IMAGE" >/dev/null
up=no
for _ in $(seq 1 30); do
  if docker exec "$gname" /garage status >/dev/null 2>&1; then up=yes; break; fi
  sleep 1
done
if [ "$up" = yes ]; then
  pass "Garage starts with the ConfigMap garage.toml and both secrets from environment variables; '/garage status' works (the probe command)"
else
  bad "Garage did not become ready: $(docker logs "$gname" 2>&1 | tail -n 5 | sed -E 's/[0-9a-f]{32,}/<hex>/g')"
fi
docker rm -f "$gname" >/dev/null 2>&1 || true

# --- admission: bare Pods rendered from the templates, server-side dry run (runs PodSecurity admission), plus a control
kubectl create --dry-run=client -f "$r/30.yaml" -o json >"$r/sts.json" 2>/dev/null || true
kubectl create --dry-run=client -f "$r/40.yaml" -o json >"$r/job.json" 2>/dev/null || true
jq '{apiVersion:"v1",kind:"Pod",metadata:{name:"objstore-psa-check",namespace:"pg-ha",labels:.spec.template.metadata.labels},spec:(.spec.template.spec | .volumes += [{"name":"data","emptyDir":{}}])}' \
  "$r/sts.json" >"$r/pod-sts.json" 2>/dev/null || true
jq '{apiVersion:"v1",kind:"Pod",metadata:{name:"objstore-init-psa-check",namespace:"pg-ha",labels:.spec.template.metadata.labels},spec:.spec.template.spec}' \
  "$r/job.json" >"$r/pod-job.json" 2>/dev/null || true
cat >"$r/pod-bad.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: objstore-psa-control
  namespace: pg-ha
spec:
  containers:
    - name: c
      image: busybox:1.37.0
      securityContext:
        privileged: true
YAML
if kubectl apply --dry-run=server -f "$r/pod-bad.yaml" >"$r/bad.txt" 2>&1; then
  bad "control: a privileged pod was admitted in pg-ha, so the admission checks below prove nothing"
else
  pass "control: a privileged pod is rejected in pg-ha ($(grep -o 'violates PodSecurity[^:]*' "$r/bad.txt" | head -n 1))"
fi
for f in pod-sts pod-job; do
  if [ ! -s "$r/$f.json" ]; then bad "$f: rendering produced an empty file"; continue; fi
  if out=$(kubectl apply --dry-run=server -f "$r/$f.json" 2>&1); then
    pass "admission accepts the $f pod (restricted profile): $out"
  else
    bad "admission rejects the $f pod: $(tail -n 3 <<<"$out")"
  fi
done

mode=$(jq -r '.spec.template.spec.volumes[] | select(.name=="tls") | .secret.defaultMode' "$r/sts.json" 2>/dev/null || true)
if [ "$mode" = "288" ]; then
  pass "Secret volume defaultMode is 288, which is octal 0440"
else
  bad "Secret volume defaultMode is '$mode', expected 288 (octal 0440)"
fi

if [ "$fail" -eq 0 ]; then echo "ALL STATIC MANIFEST CHECKS PASSED"; else echo "STATIC MANIFEST CHECKS FAILED"; fi
exit "$fail"
