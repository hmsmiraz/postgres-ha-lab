#!/usr/bin/env bash
# Prepends "EXPECTED RED LINES: ..." to evidence files, so a reviewer is not misled by deliberate failures.
# Idempotent: an existing header is replaced. Run it again after any evidence file is regenerated.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
marker="---- raw output below, unchanged ----"
add_header() {
  local f=$1 text=$2 body
  if [ ! -f "$f" ]; then echo "skip (missing): $f"; return 0; fi
  body=$(mktemp)
  if [ "$(head -n 1 "$f" | cut -c1-19)" = "EXPECTED RED LINES:" ] && [ "$(sed -n 2p "$f")" = "$marker" ]; then
    tail -n +3 "$f" >"$body"
  else
    cat "$f" >"$body"
  fi
  { printf 'EXPECTED RED LINES: %s\n%s\n' "$text" "$marker"; cat "$body"; } >"$f"
  rm -f "$body"
  echo "header set: $f"
}
e=docs/evidence
add_header "$e/ADR-0004-image-probe-run1.txt" "the two MinIO entries marked RESULT: FAILED (anonymous pull denied on Docker Hub and quay.io). That is the finding, not a defect."
add_header "$e/ADR-0004-image-probe.txt" "the two MinIO entries marked RESULT: FAILED (anonymous pull denied on Docker Hub and quay.io). That is the finding, not a defect."
add_header "$e/ADR-0004-image-pin-FAILED.txt" "all five FAIL lines are deliberate: the test was written before the pin existed (test first)."
add_header "$e/ADR-0004-image-pin.txt" "none."
add_header "$e/OBJ-1-FAILED-v1.txt" "four FAIL lines for the unset proxy variable are deliberate (test first). The final PASS for an unset variable is a bug in test v1, fixed in v2."
add_header "$e/OBJ-1-FAILED-v2.txt" "the five FAIL lines for OBJSTORE_TLS_PROXY_IMAGE are deliberate: the test was written before the pin existed."
add_header "$e/OBJ-1.txt" "none."
add_header "$e/OBJ-2-FAILED-v1.txt" "FAIL on StatefulSet objstore is deliberate (test first). Test v1 itself is invalid: it uses repo-put and repo-rm, which pgBackRest 2.60.0 does not have, and grep, which the image lacks."
add_header "$e/OBJ-2-FAILED-v2.txt" "FAIL on StatefulSet objstore is deliberate (test first). Test v2 did not verify TLS and was replaced by v3."
add_header "$e/OBJ-2-FAILED-v3.txt" "FAIL on StatefulSet objstore is deliberate (test first)."
add_header "$e/ADR-0004-garage-local-spike.txt" "RESULT pgbackrest-roundtrip rc=1 with TLS error wrong version number and STEP=stanza-create RESULT=FAIL are a deliberate demonstration that plain HTTP does not work. Exit code 0 of the script does not mean pass."
add_header "$e/ADR-0005-tls-local-spike.txt" "the negative-control ERROR 095 (no CA file) and the ports reported closed are deliberate controls."
add_header "$e/ADR-0005-init-spike.txt" "init-wrong-token with HTTP 403 and rc=1, and the loopback ports reported closed, are deliberate controls."
add_header "$e/ADR-0005-verify-spike-run1.txt" "wrong token (403) and hostname mismatch (ERROR 095) are deliberate controls. backup-large FAIL (option archive-check not valid offline) was my mistake in the script, and restart-data FAIL followed from it. Superseded by the rerun."
add_header "$e/ADR-0005-verify-spike.txt" "wrong token (403) and hostname mismatch (ERROR 095) are deliberate controls. The WARN about repo1-retention-full is real and is handled in BK-3."
add_header "$e/OBJ-static-checks-run1.txt" "git-grep-negative FAIL is an invalid control (my mistake: the test strings were hard-coded in the script, so git grep found them there). Superseded."
add_header "$e/OBJ-static-checks-run2.txt" "STEP=negative-control RESULT=FAIL is not a pass and was not explained in this run. The harness did not compare it with its expectation. Superseded by OBJ-static-checks.txt."
add_header "$e/OBJ-static-checks.txt" "STEP=negative-control RESULT=FAIL, because this harness has no S3 repository. It is reported on the negative-control RESULT line as EXPLAINED or UNEXPLAINED. There is no overall verdict in this file."
add_header "$e/OBJ-leak-detector-checks.txt" "none. NOTE: the log-grep controls here feed tiny input and cannot show the grep -q SIGPIPE hazard (see OBJ-leak-pipefail-hazard.txt). The empty-pattern-hazard line says CONFIRMED on purpose: it documents a hazard and is not a failure."
add_header "$e/ADR-0005-proxy-tags.txt" "none (listing only)."
add_header "$e/ADR-0005-proxy-probe.txt" "none."
add_header "$e/ADR-0005-garage-admin-api-schemas.txt" "none."
add_header "$e/OBJ-2-secrets-FAILED.txt" "FAIL on the missing generator script is deliberate (test first)."
add_header "$e/OBJ-2-secrets.txt" "none."
add_header "$e/OBJ-2-manifests-static-run1.txt" "INVALID. nginx -t and the Garage check ran against EMPTY files, because kubectl get does not accept --dry-run (error: unknown flag, twice). The lines syntax is ok and test is successful say nothing about our config. Superseded by OBJ-2-manifests-static.txt."
add_header "$e/OBJ-2-manifests-static.txt" "the privileged-pod control must be reported as rejected, and the empty-config control must find no 3900 listener. Both are deliberate controls."
add_header "$e/OBJ-2-up.txt" "none."
add_header "$e/OBJ-2.txt" "the INFO line gives only a count of Garage log lines that contain the access key id, a known limitation (ADR-0005 amendment 1). The PROBE lines with RESULT=closed for ports 3910, 3913 and 3901 are deliberate: Garage's own ports must be closed on the pod IP. STEP=negative-control RESULT=OK is the deliberate no-CA control."
add_header "$e/OBJ-leak-pipefail-hazard.txt" "q-form missed 5 of 5 planted secrets and c-form found 5 of 5. That is the deliberate demonstration of the hazard."
add_header "$e/OBJ-2-before-leak-fix.txt" "INVALID for the lines no secret value in any ConfigMap and no secret value in the init Job, client or object store pod logs: those scans used grep -q in a pipe and could pass without looking. The other lines are valid."
add_header "$e/OBJ-2-leak-FAILED.txt" "FAIL on the pod or Job log line is deliberate evidence of the old check: it treated the access key id as a secret, and Garage writes that id to its request log (counts in OBJ-2-leak-diagnosis.txt). The secret access key, admin token and rpc secret had no matches. Resolved by ADR-0005 amendment 1 (the key id is an identifier and is no longer scanned for in logs). Lines above the FAIL passed."
add_header "$e/OBJ-2-leak-diagnosis.txt" "none. Counts only, no log lines. An earlier version of this file held three log lines with the key id replaced by a placeholder; it was regenerated counts-only."
add_header "$e/BK-1-FAILED.txt" "FAIL on archive_mode is off is deliberate (test first)."
add_header "$e/OBJ-2-run2-FAILED.txt" "the run stops with 'line 190: tok: unbound variable'. That is my mistake: the new leak block used variable names the test does not define (shellcheck SC2154 had flagged it). It is not a leak finding. The PASS lines above it are valid for what they check; the leak checks never ran. Superseded by OBJ-2.txt."
add_header "$e/BK-1-FAILED-v2.txt" "FAIL on archive_mode is off is deliberate (test first). Test v2 changes the leak rules (ADR-0005 amendment 1) and waits for the stanza; v1 is BK-1-FAILED.txt."
add_header "$e/BK-1-static.txt" "none expected. Controls A, B and C report that the check found problems in a deliberately broken copy: that is what shows the check can fail."
