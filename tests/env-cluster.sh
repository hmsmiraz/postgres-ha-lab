#!/usr/bin/env bash
# Acceptance test: kind cluster, zones, Calico, NetworkPolicy enforcement.
set -euo pipefail

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }
ns=netpol-test
trap 'kubectl delete ns "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

echo "date: $(date -u +%FT%TZ)"
kubectl get nodes -o wide

nodes=$(kubectl get nodes --no-headers | wc -l)
[ "$nodes" -eq 4 ] || fail "expected 4 nodes, got $nodes"
notready=$(kubectl get nodes --no-headers | awk '$2 != "Ready"' | wc -l)
[ "$notready" -eq 0 ] || fail "$notready node(s) not Ready"
pass "4 nodes Ready"

zones=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' | sort -u | grep -c .)
[ "$zones" -eq 3 ] || fail "expected 3 distinct worker zones, got $zones"
pass "3 workers in 3 distinct zones"

kubectl -n kube-system rollout status ds/calico-node --timeout=120s >/dev/null || fail "calico-node not ready"
pass "calico-node running on every node"

kubectl delete ns "$ns" --ignore-not-found --wait=true >/dev/null
kubectl create ns "$ns" >/dev/null
kubectl -n "$ns" run server --image=busybox:1.37.0 --restart=Never --port=8080 -- \
  sh -c 'mkdir -p /www && echo ok > /www/index.html && httpd -f -p 8080 -h /www' >/dev/null
kubectl -n "$ns" expose pod server --port=8080 >/dev/null
kubectl -n "$ns" wait --for=condition=Ready pod/server --timeout=120s >/dev/null

# Run a client pod without attaching, then read its final phase.
# Succeeded = wget got a reply. Failed = wget timed out or was refused.
probe() {
  local name="client-$RANDOM" phase=""
  kubectl -n "$ns" run "$name" --image=busybox:1.37.0 --restart=Never -- \
    wget -qO- -T 3 http://server:8080 >/dev/null
  for _ in $(seq 1 60); do
    phase=$(kubectl -n "$ns" get pod "$name" -o jsonpath='{.status.phase}')
    case "$phase" in
      Succeeded) kubectl -n "$ns" delete pod "$name" --wait=false >/dev/null; return 0 ;;
      Failed)    kubectl -n "$ns" delete pod "$name" --wait=false >/dev/null; return 1 ;;
    esac
    sleep 2
  done
  kubectl -n "$ns" delete pod "$name" --wait=false >/dev/null
  return 1
}

probe || fail "baseline: client cannot reach server before any policy"
pass "baseline: client reaches server"

kubectl -n "$ns" apply -f - >/dev/null <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
YAML
sleep 5

if probe; then
  fail "NetworkPolicy is NOT enforced: client still reaches server"
fi
pass "NetworkPolicy enforced: traffic blocked after default-deny"
echo "ALL CHECKS PASSED"
