#!/usr/bin/env bash
# OBJ-2 (v3): object store behind TLS. See SPEC.md OBJ-2 and ADR-0004/0005.
# v1 used repo-put/repo-rm (not in pgBackRest 2.60.0) and grep (not in the image).
# v2 skipped TLS verification. v3 verifies the certificate chain, checks that plaintext ports are closed,
# and checks that no secret value leaks. Contract (change here and in the manifests together):
#   StatefulSet objstore (pod objstore-0; containers: garage and a TLS proxy), Service objstore with ports 3900 and 3903,
#   Job objstore-init, Secrets objstore-credentials (access-key-id, secret-access-key),
#   objstore-admin (admin-token, rpc-secret), objstore-tls (ca.crt, tls.crt, tls.key only), bucket pgbackrest.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. ./versions.env

NS=pg-ha
SVC=objstore
HOST="$SVC.$NS.svc.cluster.local"
BUCKET=pgbackrest
CLIENT=obj2-client
STANZA="obj2${RANDOM}"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }
k() { kubectl -n "$NS" "$@"; }
secret_field() { k get secret "$1" -o "jsonpath={.data.$2}" 2>/dev/null | base64 -d; }

pat=$(mktemp)
cleanup() {
  rm -f "$pat" "$pat.three"
  k delete job "$CLIENT" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "date: $(date -u +%FT%TZ)"

k get sts pg-ha >/dev/null 2>&1 || fail "cluster not reachable or StatefulSet pg-ha missing (bring the cluster up first)"
pass "cluster reachable, pg-ha present"

k get sts "$SVC" >/dev/null 2>&1 || fail "StatefulSet $SVC does not exist"
k rollout status "sts/$SVC" --timeout=180s >/dev/null || fail "StatefulSet $SVC is not ready"
pass "StatefulSet $SVC ready"

ports=$(k get svc "$SVC" -o json 2>/dev/null | jq -c '[.spec.ports[].port] | sort' || true)
[ "$ports" = "[3900,3903]" ] || fail "Service $SVC must expose exactly ports 3900 and 3903, found: ${ports:-none}"
pass "Service $SVC exposes exactly 3900 (S3) and 3903 (admin)"

k wait --for=condition=complete job/objstore-init --timeout=180s >/dev/null 2>&1 || fail "Job objstore-init did not complete"
initlog=$(k logs job/objstore-init 2>&1 || true)
case "$initlog" in *"INIT OK"*) ;; *) fail "Job objstore-init log does not contain INIT OK" ;; esac
pass "Job objstore-init completed and logged INIT OK"

ak=$(secret_field objstore-credentials access-key-id || true)
sk=$(secret_field objstore-credentials secret-access-key || true)
admintok=$(secret_field objstore-admin admin-token || true)
rpcsec=$(secret_field objstore-admin rpc-secret || true)
for v in "$ak" "$sk" "$admintok" "$rpcsec"; do
  [ -n "$v" ] || fail "a required Secret value is missing (objstore-credentials or objstore-admin)"
done
printf '%s\n%s\n%s\n%s\n' "$ak" "$sk" "$admintok" "$rpcsec" >"$pat"
pass "Secrets objstore-credentials and objstore-admin have all four values (values not printed)"

tlskeys=$(k get secret objstore-tls -o json 2>/dev/null | jq -c '[.data | keys[]] | sort' || true)
[ "$tlskeys" = '["ca.crt","tls.crt","tls.key"]' ] \
  || fail "Secret objstore-tls must hold exactly ca.crt, tls.crt and tls.key (no CA private key), found: ${tlskeys:-none}"
pass "Secret objstore-tls holds exactly ca.crt, tls.crt, tls.key (no CA private key in the cluster)"

pod_ip=$(k get pod "${SVC}-0" -o jsonpath='{.status.podIP}' 2>/dev/null || true)
[ -n "$pod_ip" ] || fail "pod ${SVC}-0 has no IP"
uid=$(k get sts pg-ha -o jsonpath='{.spec.template.spec.securityContext.runAsUser}' 2>/dev/null || true)
uid=${uid:-999}

k delete job "$CLIENT" --ignore-not-found --wait=true >/dev/null
sed -e "s|__CLIENT__|$CLIENT|" -e "s|__IMAGE__|${IMAGE_NAME}:${IMAGE_TAG}|" -e "s|__UID__|$uid|" \
    -e "s|__HOST__|$HOST|g" -e "s|__POD_IP__|$pod_ip|g" \
    -e "s|__BUCKET__|$BUCKET|" -e "s|__STANZA__|$STANZA|" <<'YAML' | k apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: __CLIENT__
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 240
  template:
    spec:
      automountServiceAccountToken: false
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: __UID__
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: client
          image: __IMAGE__
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - {name: tls, mountPath: /certs, readOnly: true}
          env:
            - {name: PGBACKREST_STANZA, value: __STANZA__}
            - {name: PGBACKREST_PG1_PATH, value: /tmp/pgdata}
            - {name: PGBACKREST_LOG_LEVEL_CONSOLE, value: warn}
            - {name: PGBACKREST_LOG_LEVEL_FILE, value: "off"}
            - {name: PGBACKREST_REPO1_TYPE, value: s3}
            - {name: PGBACKREST_REPO1_PATH, value: /obj2-test}
            - {name: PGBACKREST_REPO1_S3_BUCKET, value: __BUCKET__}
            - {name: PGBACKREST_REPO1_S3_ENDPOINT, value: __HOST__}
            - {name: PGBACKREST_REPO1_STORAGE_PORT, value: "3900"}
            - {name: PGBACKREST_REPO1_S3_REGION, value: garage}
            - {name: PGBACKREST_REPO1_S3_URI_STYLE, value: path}
            - {name: PGBACKREST_REPO1_STORAGE_CA_FILE, value: /certs/ca.crt}
            - name: PGBACKREST_REPO1_S3_KEY
              valueFrom: {secretKeyRef: {name: objstore-credentials, key: access-key-id}}
            - name: PGBACKREST_REPO1_S3_KEY_SECRET
              valueFrom: {secretKeyRef: {name: objstore-credentials, key: secret-access-key}}
          command: ["sh", "-c"]
          args:
            - |
              set -u
              step_fail() { echo "STEP=$1 RESULT=FAIL"; exit 1; }
              probe() {
                r=$(python3 -c '
              import socket, sys
              s = socket.socket()
              s.settimeout(3)
              try:
                  s.connect((sys.argv[1], int(sys.argv[2])))
                  print("open")
              except Exception as e:
                  print("closed")
              ' "$1" "$2" 2>&1 | tail -n 1)
                echo "PROBE host=$1 port=$2 RESULT=$r"
              }
              probe __HOST__ 3900
              probe __HOST__ 3903
              probe __POD_IP__ 3910
              probe __POD_IP__ 3913
              probe __POD_IP__ 3901
              neg=$(env -u PGBACKREST_REPO1_STORAGE_CA_FILE pgbackrest repo-ls backup </dev/null 2>&1) && step_fail negative-control
              case "$neg" in *certificate*) echo "STEP=negative-control RESULT=OK" ;; *) echo "STEP=negative-control RESULT=FAIL (unexpected error)"; exit 1 ;; esac
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
      volumes:
        - name: tls
          secret:
            secretName: objstore-tls
            items:
              - {key: ca.crt, path: ca.crt}
YAML

phase=""
for _ in $(seq 1 120); do
  phase=$(k get pods -l "batch.kubernetes.io/job-name=$CLIENT" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  if [ "$phase" = Succeeded ] || [ "$phase" = Failed ]; then break; fi
  sleep 2
done
out=$(k logs "job/$CLIENT" 2>&1 || true)
echo "--- client log (final phase: ${phase:-unknown})"
echo "$out"
echo "---"

for want in "host=$HOST port=3900 RESULT=open" "host=$HOST port=3903 RESULT=open" \
            "host=$pod_ip port=3910 RESULT=closed" "host=$pod_ip port=3913 RESULT=closed" "host=$pod_ip port=3901 RESULT=closed"; do
  grep -qF "PROBE $want" <<<"$out" || fail "port probe failed: expected '$want'"
done
pass "TLS ports 3900 and 3903 open via the Service; Garage S3 (3910), admin (3913) and RPC (3901) closed on the pod IP"

grep -q "STEP=negative-control RESULT=OK" <<<"$out" || fail "without the CA file pgBackRest did not fail with a certificate error"
pass "negative control: without the CA, pgBackRest rejects the certificate"

for step in initdb stanza-create ls get stanza-delete cleanup; do
  grep -q "STEP=$step RESULT=OK" <<<"$out" || fail "pgBackRest round trip step '$step' did not succeed"
done
pass "pgBackRest over verified TLS: write (stanza-create), ls, get, delete (stanza-delete), repository clean"

# Leak checks (ADR-0005 amendment 1). Four values: access key id, secret access key, admin token, rpc secret.
# Repo files, evidence files and ConfigMaps: none of the four may appear. Logs: none of the three access-granting values
# (secret access key, admin token, rpc secret) may appear. Garage writes the access key id, an identifier, to its request
# log, so only a count of those lines is printed. Scans use grep -c or -l (they read all input): "producer | grep -q" can
# miss a match under pipefail (docs/evidence/OBJ-leak-pipefail-hazard.txt).
( umask 077; printf '%s\n%s\n%s\n' "$sk" "$admintok" "$rpcsec" >"$pat.three" )
n=$(printf 'control with %s inside\n' "$sk" | grep -F -c -f "$pat.three" || true)
[ "${n:-0}" = 1 ] || fail "log scanner control did not fire on a planted secret access key"
n=$(printf 'control with %s inside\n' "$ak" | grep -F -c -f "$pat.three" || true)
[ "${n:-0}" = 0 ] || fail "log scanner control: the three-value pattern matches the access key id, which it must not"
pass "log scanner controls: it fires on a planted secret value and ignores the access key id"

files=$(git grep --untracked -I -F -l -f "$pat" || true)
if [ -n "$files" ]; then
  while IFS= read -r fname; do echo "  file: $fname"; done <<<"$files"
  fail "a secret value or the access key id was found in a repo file (names listed above, no content)"
fi
pass "none of the four values in any repo file (working tree only, not history)"

files=$(grep -r -F -l -f "$pat" docs/evidence 2>/dev/null || true)
if [ -n "$files" ]; then
  while IFS= read -r fname; do echo "  file: $fname"; done <<<"$files"
  fail "a secret value or the access key id was found in an evidence file (names listed above, no content)"
fi
pass "none of the four values in any file under docs/evidence"

n=$(k get configmap -o json 2>/dev/null | grep -F -c -f "$pat" || true)
if [ "${n:-0}" -ne 0 ]; then fail "a secret value or the access key id was found in a ConfigMap"; fi
pass "none of the four values in any ConfigMap of namespace $NS"

leak=0
n=$(grep -F -c -f "$pat.three" <<<"$initlog" || true)
if [ "${n:-0}" -ne 0 ]; then leak=1; fi
n=$(grep -F -c -f "$pat.three" <<<"$out" || true)
if [ "${n:-0}" -ne 0 ]; then leak=1; fi
n=$(k logs "${SVC}-0" --all-containers 2>&1 | grep -F -c -f "$pat.three" || true)
if [ "${n:-0}" -ne 0 ]; then leak=1; fi
[ "$leak" -eq 0 ] || fail "the secret access key, the admin token or the rpc secret was found in a pod or Job log"
pass "none of the three access-granting values appears in the init Job, client or object store pod logs"
n=$(k logs "${SVC}-0" -c garage 2>&1 | grep -F -c -e "$ak" || true)
echo "INFO: the access key id appears in ${n:-0} lines of the Garage log (known limitation, ADR-0005 amendment 1; count only)"
echo "ALL CHECKS PASSED"
