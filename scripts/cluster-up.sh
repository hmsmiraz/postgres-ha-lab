#!/usr/bin/env bash
# Create the kind cluster, install Calico, label workers with fake zones.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source versions.env

CLUSTER=${KIND_CLUSTER_NAME:-kind}
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "kind cluster '$CLUSTER' already exists, reusing it"
else
  kind create cluster --name "$CLUSTER" \
    --config k8s/kind-config.yaml \
    --image "kindest/node:${KIND_NODE_IMAGE}"
  # Load the CNI once from the host so four cold nodes do not race registry pulls.
  for component in cni node kube-controllers; do
    image="quay.io/calico/${component}:${CALICO_VERSION}"
    docker pull "$image"
    kind load docker-image "$image" --name "$CLUSTER"
  done
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null

kubectl apply -f "k8s/calico/calico-${CALICO_VERSION}.yaml"
kubectl -n kube-system rollout status ds/calico-node --timeout=300s
kubectl -n kube-system rollout status deploy/calico-kube-controllers --timeout=300s
kubectl wait --for=condition=Ready nodes --all --timeout=300s

zones=(zone-a zone-b zone-c)
i=0
for n in $(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | sort); do
  kubectl label --overwrite "$n" "topology.kubernetes.io/zone=${zones[$i]}"
  i=$((i + 1))
done
kubectl get nodes -L topology.kubernetes.io/zone
