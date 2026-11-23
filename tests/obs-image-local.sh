#!/usr/bin/env bash
# OBS-1: the four monitoring images, loaded by name:tag with "kind load", resolve from the node image store
# with imagePullPolicy Never (nothing is pulled from the internet). A pod for an image that exists
# nowhere is the negative control and must show ErrImageNeverPull.
# The scratch namespace obs-imgtest is created and deleted by this test; it refuses to run if it exists.
# The digest form cannot resolve here (kind load re-exports the image, see docs/evidence/OBS-1-image-local-FAILED.txt), so the tag form is tested. The digest is checked on the host by tests/obs-image.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source versions.env

NS=obs-imgtest
fail=0
report() {
  if [ "$2" -eq 0 ]; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi
}

if kubectl get ns "$NS" >/dev/null 2>&1; then
  echo "namespace $NS already exists, refusing to run"; exit 2
fi
trap 'kubectl delete ns "$NS" --wait=true >/dev/null 2>&1 || true' EXIT
kubectl create ns "$NS" >/dev/null
kubectl label ns "$NS" pod-security.kubernetes.io/enforce=restricted >/dev/null

mk_pod() { # name image uid
  kubectl -n "$NS" apply -f - >/dev/null <<EOP
apiVersion: v1
kind: Pod
metadata:
  name: $1
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: $3
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: c
      image: $2
      imagePullPolicy: Never
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
EOP
}

outcome() { # pod -> never | started | timeout
  local pod=$1 r id
  for _ in $(seq 1 45); do
    r=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
    if [ "$r" = ErrImageNeverPull ]; then echo never; return; fi
    id=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null || true)
    if [ -n "$id" ]; then echo started; return; fi
    sleep 2
  done
  echo timeout
}

echo "date_utc: $(date -u +%FT%TZ)"
mk_pod t-prometheus "${PROMETHEUS_IMAGE%%@*}" 65534
mk_pod t-exporter "${PG_EXPORTER_IMAGE%%@*}" 65534
mk_pod t-ksm "${KSM_IMAGE%%@*}" 65534
mk_pod t-grafana "${GRAFANA_IMAGE%%@*}" 472
mk_pod t-absent "docker.io/library/obs-imgtest-absent:0" 65534

for p in t-prometheus t-exporter t-ksm t-grafana; do
  o=$(outcome "$p")
  echo "$p: $o"
  rc=1; if [ "$o" = started ]; then rc=0; fi
  report "$p resolves its pinned image from the node store (Never)" "$rc"
done
o=$(outcome t-absent)
echo "t-absent: $o"
rc=1; if [ "$o" = never ]; then rc=0; fi
report "negative control: an absent image shows ErrImageNeverPull" "$rc"
exit "$fail"
