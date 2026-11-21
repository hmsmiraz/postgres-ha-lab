#!/usr/bin/env bash
# Checks the assumptions made before the object store manifests are written. Changes nothing in the cluster
# (the pod check is a server-side dry run). There is NO overall verdict: read the RESULT lines.
# Section 4 compares the probe output with its stated expectation (MATCH or MISMATCH). The negative-control
# step of the pod script cannot be evaluated here, because this harness has no S3 repository: it is reported
# as EXPLAINED or UNEXPLAINED, never as a pass. Certificate verification is checked in tests/obj-s3.sh and
# was shown in docs/evidence/ADR-0005-tls-local-spike.txt.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. ./versions.env
pg_image="${IMAGE_NAME}:${IMAGE_TAG}"
tmp=$(mktemp -d)
chmod 777 "$tmp"
trap 'rm -rf "$tmp"' EXIT
res() { echo "RESULT $1: $2"; }

echo "date_utc: $(date -u +%FT%TZ)"
echo "garage: $OBJSTORE_IMAGE"

echo "--- 1. Garage v2.5.0: secret options and their environment variables"
help=$(docker run --rm --entrypoint /garage "$OBJSTORE_IMAGE" --help 2>&1) || true
grep -E -i 'rpc-secret|admin-token|GARAGE_' <<<"$help" || echo "(no matching lines in --help)"
for v in GARAGE_RPC_SECRET GARAGE_ADMIN_TOKEN; do
  if grep -q "$v" <<<"$help"; then res "env-$v" "listed in --help"; else res "env-$v" "not listed in --help (verify-objstore.sh decides)"; fi
done

echo "--- 2. tools in the pg-ha image"
docker run --rm --entrypoint sh "$pg_image" -c 'for c in env sh python3 dd; do printf "%s: " "$c"; command -v "$c" || echo MISSING; done'

echo "--- 3. kubectl jsonpath with a hyphenated key, on the existing pg-credentials Secret (length only, value not printed)"
len=$(kubectl -n pg-ha get secret pg-credentials -o 'jsonpath={.data.superuser-password}' 2>/dev/null | base64 -d | wc -c)
echo "decoded length: $len"
if [ "$len" -gt 0 ]; then res jsonpath-hyphen OK; else res jsonpath-hyphen FAIL; fi
kubectl -n pg-ha get secret pg-credentials -o json | jq -c '[.data | keys[]] | sort'

echo "--- 4. client pod from tests/obj-s3.sh: render, server-side dry run, script syntax, probe output"
sed -n '/<<.YAML. | k apply/,/^YAML$/p' tests/obj-s3.sh | sed '1d;$d' >"$tmp/pod.tpl.yaml"
echo "template lines: $(wc -l <"$tmp/pod.tpl.yaml")"
sed -e 's|__CLIENT__|obj2-client|' -e 's|__IMAGE__|pg-ha:test|' -e 's|__UID__|999|' \
    -e 's|__HOST__|127.0.0.1|g' -e 's|__POD_IP__|127.0.0.1|g' -e 's|__BUCKET__|pgbackrest|' -e 's|__STANZA__|obj2test|' \
    "$tmp/pod.tpl.yaml" >"$tmp/pod.yaml"
if out=$(kubectl -n pg-ha apply --dry-run=server -f "$tmp/pod.yaml" 2>&1); then
  res pod-dry-run "OK ($out)"
else
  res pod-dry-run FAIL
  echo "$out" | tail -n 8
fi
if docker run --rm -v "$tmp:/w" --entrypoint python3 "$pg_image" -c '
import yaml
d = yaml.safe_load(open("/w/pod.yaml"))
s = d["spec"]["containers"][0]["args"][0]
open("/w/script.sh", "w").write(s)
print("yaml OK, script lines:", len(s.splitlines()))
'; then res yaml-parse OK; else res yaml-parse FAIL; fi
if [ -s "$tmp/script.sh" ]; then
  if docker run --rm -v "$tmp:/w:ro" --entrypoint sh "$pg_image" -n /w/script.sh; then res shell-syntax OK; else res shell-syntax FAIL; fi
  echo "--- script run with nothing listening (expectation: 5 probes closed; the negative control cannot be evaluated here)"
  run_out=$(docker run --rm -v "$tmp:/w:ro" --entrypoint sh "$pg_image" /w/script.sh 2>&1) || true
  echo "$run_out" | head -n 12
  closed=$(grep -c 'RESULT=closed' <<<"$run_out" || true)
  if [ "$closed" -eq 5 ]; then res probes "MATCH (5 of 5 closed, as expected)"; else res probes "MISMATCH ($closed of 5 closed, expected 5)"; fi
  nc_line=$(grep -m1 'STEP=negative-control' <<<"$run_out" || true)
  direct_rc=0
  direct_out=$(docker run --rm --entrypoint pgbackrest "$pg_image" repo-ls backup </dev/null 2>&1) || direct_rc=$?
  echo "direct check, pgbackrest repo-ls backup with no S3 settings: rc=$direct_rc output=[$(head -c 200 <<<"$direct_out")]"
  if [ "$nc_line" = "STEP=negative-control RESULT=FAIL" ] && [ "$direct_rc" -eq 0 ]; then
    res negative-control "EXPLAINED, not evaluated: pgBackRest exits 0 without an S3 repository, so the pod script takes its 'command succeeded' branch. This harness cannot test certificate verification."
  elif [ -z "$nc_line" ]; then
    res negative-control "UNEXPLAINED: the pod script printed no negative-control line"
  else
    res negative-control "UNEXPLAINED: observed '$nc_line', direct rc=$direct_rc"
  fi
fi
echo "STATIC CHECKS DONE (no overall verdict; the negative control is not evaluated here)"
