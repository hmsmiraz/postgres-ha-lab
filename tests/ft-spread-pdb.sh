#!/usr/bin/env bash
# FT-1: pods are spread across nodes and zones, and anti-affinity is enforced (a 4th pod cannot be scheduled).
# FT-2: PDB, resource requests/limits, probes and a termination grace period are set, and the PDB
#       blocks a second node drain while one replica is already out.
set -Eeuo pipefail
trap 'echo "FAIL: command failed at line $LINENO: $BASH_COMMAND"' ERR
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source tests/lib/probe.sh

drained=""
cleanup() {
  kubectl -n "$NS" scale sts/pg-ha --replicas=3 >/dev/null 2>&1 || true
  kubectl -n "$NS" delete pvc data-pg-ha-3 --ignore-not-found --wait=false >/dev/null 2>&1 || true
  for n in $drained; do kubectl uncordon "$n" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

echo "date: $(date -u +%FT%TZ)"
wait_healthy 120 || fail "cluster is not healthy before the test"

echo "--- FT-1: placement ---"
sts=$(kubectl -n "$NS" get sts pg-ha -o json)
jq -e '.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution | length > 0' <<<"$sts" >/dev/null \
  || fail "no required pod anti-affinity on the StatefulSet"
pass "required pod anti-affinity (one pod per node) is configured"
jq -e '.spec.template.spec.topologySpreadConstraints | map(select(.topologyKey == "topology.kubernetes.io/zone" and .whenUnsatisfiable == "DoNotSchedule")) | length > 0' <<<"$sts" >/dev/null \
  || fail "no zone topology spread constraint with DoNotSchedule"
pass "zone topology spread constraint (DoNotSchedule) is configured"

pods_json=$(kubectl -n "$NS" get pods -l application=pg-ha,cluster-name=pg-ha -o json)
echo "pod -> node -> zone:"
zones_list=""
for row in $(jq -r '.items[] | .metadata.name + "=" + .spec.nodeName' <<<"$pods_json" | sort); do
  p=${row%%=*}; nd=${row#*=}
  z=$(kubectl get node "$nd" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
  echo "  $p -> $nd -> $z"
  zones_list="$zones_list $z"
done
nodes_n=$(jq -r '.items[].spec.nodeName' <<<"$pods_json" | sort -u | wc -l)
zones_n=$(tr ' ' '\n' <<<"$zones_list" | sort -u | grep -c . || true)
[ "$nodes_n" = 3 ] || fail "expected the 3 pods on 3 distinct nodes, found $nodes_n"
pass "3 pods on 3 distinct nodes"
[ "$zones_n" = 3 ] || fail "expected 3 distinct zones, found $zones_n"
pass "3 pods in 3 distinct zones"

echo "scaling to 4 replicas to prove anti-affinity is enforced"
kubectl -n "$NS" scale sts/pg-ha --replicas=4 >/dev/null
msg=""; phase=""
for _ in $(seq 1 30); do
  phase=$(kubectl -n "$NS" get pod pg-ha-3 -o jsonpath='{.status.phase}' 2>/dev/null || true)
  msg=$(kubectl -n "$NS" get pod pg-ha-3 -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null || true)
  if [ "$phase" = Pending ] && [ -n "$msg" ]; then break; fi
  sleep 3
done
echo "scheduler message for the 4th pod: ${msg:-<none>}"
[ "$phase" = Pending ] || fail "the 4th pod is '$phase'; it should stay Pending"
grep -qi "anti-affinity" <<<"$msg" || fail "the 4th pod is Pending, but not because of anti-affinity: $msg"
pass "a 4th pod cannot be scheduled: anti-affinity is enforced"
kubectl -n "$NS" scale sts/pg-ha --replicas=3 >/dev/null
kubectl -n "$NS" delete pvc data-pg-ha-3 --ignore-not-found --wait=false >/dev/null

echo "--- FT-2: disruption budget, resources, probes ---"
min=$(kubectl -n "$NS" get pdb pg-ha -o jsonpath='{.spec.minAvailable}')
[ "$min" = 2 ] || fail "PDB minAvailable is '$min', expected 2"
pass "PodDisruptionBudget minAvailable = 2"
c=$(jq '.spec.template.spec.containers[0]' <<<"$sts")
jq -e '.resources.requests.cpu and .resources.requests.memory and .resources.limits.memory' <<<"$c" >/dev/null \
  || fail "resource requests or the memory limit are missing"
pass "resource requests and a memory limit are set"
jq -e '.startupProbe and .livenessProbe and .readinessProbe' <<<"$c" >/dev/null || fail "a probe is missing"
pass "startup, liveness and readiness probes are set"
grace=$(jq -r '.spec.template.spec.terminationGracePeriodSeconds' <<<"$sts")
[ "$grace" -ge 30 ] || fail "terminationGracePeriodSeconds is $grace"
pass "terminationGracePeriodSeconds = $grace"

leader=$(current_leader)
async=$(cluster_json | jq -r '.[] | select(.Role == "Replica") | .Member' | head -1)
syncpod=$(cluster_json | jq -r '.[] | select(.Role == "Sync Standby") | .Member' | head -1)
[ -n "$async" ] && [ -n "$syncpod" ] || fail "need one async replica and one sync standby"
node_a=$(kubectl -n "$NS" get pod "$async" -o jsonpath='{.spec.nodeName}')
node_b=$(kubectl -n "$NS" get pod "$syncpod" -o jsonpath='{.spec.nodeName}')
echo "leader $leader (untouched); async replica $async on $node_a; sync standby $syncpod on $node_b"
drained="$node_a $node_b"

echo "draining $node_a (one replica goes out)"
timeout 170 kubectl drain "$node_a" --ignore-daemonsets --delete-emptydir-data --timeout=150s
pass "the PDB allowed one replica to be evicted"
allowed=""
for _ in $(seq 1 30); do
  allowed=$(kubectl -n "$NS" get pdb pg-ha -o jsonpath='{.status.disruptionsAllowed}')
  if [ "$allowed" = 0 ]; then break; fi
  sleep 3
done
echo "PDB disruptionsAllowed with one replica out: $allowed"
[ "$allowed" = 0 ] || fail "PDB still allows $allowed disruption(s) with one replica out"
pass "PDB now allows 0 further disruptions"

rw=$(sql_primary "select pg_is_in_recovery()") || fail "cannot reach the primary while a node is drained"
[ "$rw" = "f" ] || fail "pg-primary is not a primary while a node is drained: $rw"
pass "the cluster still serves writes while a replica is out"

echo "trying to drain $node_b (hosts the sync standby $syncpod) while $async is out"
if out=$(timeout 120 kubectl drain "$node_b" --ignore-daemonsets --delete-emptydir-data --timeout=40s 2>&1); then
  printf '%s\n' "$out" | tail -6
  fail "the drain of $node_b succeeded; the PDB did not protect the cluster"
fi
printf '%s\n' "$out" | tail -6
echo "PDB message from the drain: $(grep -i -m1 "disruption budget" <<<"$out" || echo "<not found>")"
grep -qi "disruption budget" <<<"$out" || fail "the drain failed, but not because of the disruption budget"
pass "the PDB blocked a second drain (it would have left fewer than 2 pods available)"
phase=$(kubectl -n "$NS" get pod "$syncpod" -o jsonpath='{.status.phase}')
[ "$phase" = Running ] || fail "the sync standby $syncpod is '$phase' after the blocked drain"
pass "the sync standby $syncpod is untouched and still Running"

echo "uncordoning both nodes"
kubectl uncordon "$node_a" "$node_b" >/dev/null
drained=""
wait_healthy 400 || { cluster_table || true; fail "cluster did not return to 1 leader + 2 streaming replicas"; }
cluster_table
pass "cluster is back to 1 leader + 2 streaming replicas"
kubectl -n "$NS" get pdb pg-ha

n=$(writable_primaries)
[ "$n" = 1 ] || fail "$n pods accept writes, expected exactly 1"
pass "exactly one pod accepts writes"
echo "ALL CHECKS PASSED"
