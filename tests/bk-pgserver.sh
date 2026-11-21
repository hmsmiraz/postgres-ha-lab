#!/usr/bin/env bash
# BK-2 (pgserver sidecar, ADR-0002): every pg-ha pod runs a "pgserver" container (pgbackrest server, TLS on port 8432,
# listening on 0.0.0.0, client authorised as pgbackrest-backup for stanza pg-ha). A scratch pod with the client Secret
# runs "pgbackrest check" against the three pods as pg1, pg2 and pg3. It must succeed with the client certificate and fail
# with no client certificate and with a self-signed certificate of the same name (negative controls).
# Not covered here: authorisation by certificate name and stanza (the cluster holds no CA key to sign another name),
# and which pod a backup chooses.
# Leak scans use grep -c, never "producer | grep -q". Nothing printed holds key content.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source versions.env
# shellcheck source=/dev/null
source tests/lib/probe.sh

SRVSEC=pgbackrest-tls-server
CLISEC=pgbackrest-tls-client
OTHER=bk-pgserver-test-other
TP=bk-pgserver-test
IMG="${IMAGE_NAME}:${IMAGE_TAG}"
k() { kubectl -n "$NS" "$@"; }
keys_of() { k get secret "$1" -o json 2>/dev/null | jq -c '[.data | keys[]] | sort'; }
host() { echo "pg-ha-$1.pg-ha-headless.$NS.svc.cluster.local"; }

umask 077
work=$(mktemp -d)
# shellcheck disable=SC2329
cleanup() {
  k delete pod "$TP" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  k delete secret "$OTHER" --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

rc=0
out=""
run_check() {
  local certdir=$1 i
  local a=(--stanza=pg-ha --log-level-console=warn)
  for i in 1 2 3; do
    a+=("--pg$i-host=$(host $((i - 1)))" "--pg$i-host-type=tls" "--pg$i-host-ca-file=/client/ca.crt" "--pg$i-path=/pgdata/data" "--pg$i-socket-path=/run/postgresql")
    if [ "$certdir" != none ]; then
      a+=("--pg$i-host-cert-file=$certdir/tls.crt" "--pg$i-host-key-file=$certdir/tls.key")
    fi
  done
  rc=0
  out=$(timeout 240 kubectl -n "$NS" exec "$TP" -c client -- pgbackrest "${a[@]}" check </dev/null 2>&1) || rc=$?
}

echo "date: $(date -u +%FT%TZ)"
k get sts pg-ha >/dev/null 2>&1 || fail "StatefulSet pg-ha is missing"
pods=$(k get pods -l application=pg-ha,cluster-name=pg-ha -o json)

n=$(jq '[.items[] | select(any(.spec.containers[]; .name == "pgserver"))] | length' <<<"$pods")
[ "$n" = 3 ] || fail "expected a pgserver container in 3 pods, found it in $n"
n=$(jq '[.items[].status.containerStatuses[] | select(.name == "pgserver" and .ready == true)] | length' <<<"$pods")
[ "$n" = 3 ] || fail "expected 3 ready pgserver containers, found $n"
n=$(jq '[.items[].status.containerStatuses[] | select(.name == "pgserver") | .restartCount] | add' <<<"$pods")
[ "$n" = 0 ] || fail "pgserver containers restarted $n times"
n=$(jq '[.items[].spec.containers[] | select(.name == "pgserver" and .command == ["pgbackrest","server"])] | length' <<<"$pods")
[ "$n" = 3 ] || fail "pgserver must run 'pgbackrest server' in all 3 pods, found $n"
n=$(jq '[.items[].spec.containers[] | select(.name == "pgserver") | .env[]? | select(.name == "PGBACKREST_TLS_SERVER_ADDRESS" and .value == "0.0.0.0")] | length' <<<"$pods")
[ "$n" = 3 ] || fail "PGBACKREST_TLS_SERVER_ADDRESS must be 0.0.0.0 in all 3 pods, found $n"
n=$(jq '[.items[].spec.containers[] | select(.name == "pgserver") | .env[]? | select(.name == "PGBACKREST_TLS_SERVER_AUTH" and .value == "pgbackrest-backup=pg-ha")] | length' <<<"$pods")
[ "$n" = 3 ] || fail "PGBACKREST_TLS_SERVER_AUTH must be pgbackrest-backup=pg-ha in all 3 pods, found $n"
pass "3 ready pgserver containers with no restarts, the right command, address and authorised client"

[ "$(keys_of "$SRVSEC")" = '["ca.crt","tls.crt","tls.key"]' ] || fail "$SRVSEC must hold exactly ca.crt, tls.crt and tls.key"
[ "$(keys_of "$CLISEC")" = '["ca.crt","tls.crt","tls.key"]' ] || fail "$CLISEC must hold exactly ca.crt, tls.crt and tls.key"
pass "both TLS Secrets exist with exactly ca.crt, tls.crt and tls.key"

wait_healthy 120 || fail "Patroni does not report 1 leader and 2 streaming replicas"
pass "Patroni reports 1 leader and 2 streaming replicas"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=pgbackrest-backup" \
  -keyout "$work/o.key" -out "$work/o.crt" >/dev/null 2>&1
[ -s "$work/o.crt" ] && [ -s "$work/o.key" ] || fail "could not create the self-signed control certificate"
k create secret generic "$OTHER" --from-file=tls.crt="$work/o.crt" --from-file=tls.key="$work/o.key" >/dev/null

k delete pod "$TP" --ignore-not-found --wait=true >/dev/null
# defaultMode 288 is octal 0440: readable by group 999 through fsGroup.
kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $TP
  namespace: $NS
  labels:
    app: $TP
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
    runAsGroup: 999
    fsGroup: 999
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: client
      image: $IMG
      imagePullPolicy: IfNotPresent
      command: ["sleep", "3600"]
      envFrom:
        - configMapRef:
            name: pgbackrest-env
      env:
        - name: PGBACKREST_REPO1_S3_KEY
          valueFrom:
            secretKeyRef:
              name: objstore-credentials
              key: access-key-id
        - name: PGBACKREST_REPO1_S3_KEY_SECRET
          valueFrom:
            secretKeyRef:
              name: objstore-credentials
              key: secret-access-key
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 10m
          memory: 64Mi
        limits:
          memory: 256Mi
      volumeMounts:
        - name: client
          mountPath: /client
          readOnly: true
        - name: other
          mountPath: /other
          readOnly: true
        - name: objstore-ca
          mountPath: /certs
          readOnly: true
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: client
      secret:
        secretName: $CLISEC
        defaultMode: 288
    - name: other
      secret:
        secretName: $OTHER
        defaultMode: 288
    - name: objstore-ca
      secret:
        secretName: objstore-tls
        items:
          - key: ca.crt
            path: ca.crt
    - name: tmp
      emptyDir: {}
YAML
k wait --for=condition=Ready "pod/$TP" --timeout=120s >/dev/null || fail "the scratch client pod did not become ready"
pass "scratch client pod is ready"

run_check /client
if [ "$rc" != 0 ]; then
  echo "$out" | tail -n 8
  fail "pgbackrest check through the three pgserver endpoints failed (exit $rc)"
fi
pass "pgbackrest check succeeds through the three pgserver endpoints with the client certificate"

run_check none
[ "$rc" != 0 ] || fail "negative control: the check succeeded with no client certificate"
[ -n "$out" ] || fail "negative control: the failed check printed nothing, so the control proves nothing"
pass "negative control: with no client certificate the check fails"

run_check /other
[ "$rc" != 0 ] || fail "negative control: the check succeeded with a self-signed certificate of the same name"
[ -n "$out" ] || fail "negative control: the failed check printed nothing, so the control proves nothing"
pass "negative control: a self-signed certificate of the same name is refused"
echo "ALL CHECKS PASSED"
