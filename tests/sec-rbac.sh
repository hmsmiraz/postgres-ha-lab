#!/usr/bin/env bash
# SEC-4: least-privilege RBAC. Read only (kubectl auth can-i). Prints yes/no answers, no secret.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
ok() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
can() { # as-account namespace verb resource -> yes|no|empty
  kubectl auth can-i "$3" "$4" -n "$2" --as="system:serviceaccount:$2:$1" 2>/dev/null | head -n 1
}
want() { # description expected answer
  if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (answer: '${3:-empty}', expected $2)"; fi
}
P=patroni; K=kube-state-metrics
echo "date_utc: $(date -u +%FT%TZ)"

want "control: admin identity can get secrets (the check can say yes)" yes "$(kubectl auth can-i get secrets -n pg-ha 2>/dev/null | head -n 1)"
want "patroni can get configmaps in pg-ha" yes "$(can $P pg-ha get configmaps)"
want "patroni can patch pods in pg-ha" yes "$(can $P pg-ha patch pods)"
want "patroni cannot get secrets in pg-ha" no "$(can $P pg-ha get secrets)"
want "patroni cannot create pods in pg-ha" no "$(can $P pg-ha create pods)"
want "patroni cannot delete pods in pg-ha" no "$(can $P pg-ha delete pods)"
want "patroni cannot create deployments in pg-ha" no "$(can $P pg-ha create deployments)"
want "patroni cannot get secrets in pg-restore" no "$(kubectl auth can-i get secrets -n pg-restore --as=system:serviceaccount:pg-ha:$P 2>/dev/null | head -n 1)"
want "patroni cannot list nodes" no "$(kubectl auth can-i list nodes --as=system:serviceaccount:pg-ha:$P 2>/dev/null | head -n 1)"
want "kube-state-metrics cannot get secrets" no "$(can $K pg-ha get secrets)"
want "kube-state-metrics cannot create pods" no "$(can $K pg-ha create pods)"
want "default account in pg-ha cannot get secrets" no "$(can default pg-ha get secrets)"

n=$(grep -cE '"?secrets"?|\["\*"\]|"\*"' k8s/pg/10-rbac.yaml || true)
m=$(grep -cE 'secrets|"\*"' k8s/obs/10-rbac.yaml || true)
if [ -s k8s/pg/10-rbac.yaml ] && [ -s k8s/obs/10-rbac.yaml ] && [ "$n$m" = "00" ]; then ok "RBAC manifests name no secrets resource and no wildcard"; else bad "RBAC manifests name no secrets resource and no wildcard ($n, $m)"; fi

echo "ACCEPTED (not asserted): patroni can delete configmaps: $(can $P pg-ha delete configmaps); deletecollection: $(can $P pg-ha deletecollection configmaps). Need not tested."
exit "$fail"
