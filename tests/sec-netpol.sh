#!/usr/bin/env bash
# SEC-3 (option C): NetworkPolicies on the Postgres pods and the object store. A blocked connection is demonstrated.
# Live. Creates two short-lived pods in pg-ha (netpol-intruder, netpol-allowed) and deletes them at the end.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
source tests/lib/probe.sh
# shellcheck source=/dev/null
source versions.env
PGIMG="${IMAGE_NAME}:${IMAGE_TAG}"
fail=0
ok() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
trap 'kubectl -n "$NS" delete pod netpol-intruder netpol-allowed --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

mk() { # name label-app
  kubectl -n "$NS" apply -f - >/dev/null <<EOP
apiVersion: v1
kind: Pod
metadata:
  name: $1
  labels:
    app: $2
spec:
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: c
      image: ${PGIMG}
      imagePullPolicy: Never
      command: ["sleep", "600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
EOP
}
reach() { kubectl -n "$NS" exec "$1" -- python3 -c 'import socket,sys;s=socket.socket();s.settimeout(3);sys.exit(0 if s.connect_ex((sys.argv[1],int(sys.argv[2])))==0 else 1)' "$2" "$3" >/dev/null 2>&1; }
py() { kubectl -n "$1" exec "$2" -c postgres -- python3 -c 'import socket,sys;s=socket.socket();s.settimeout(3);sys.exit(0 if s.connect_ex((sys.argv[1],int(sys.argv[2])))==0 else 1)' "$3" "$4" >/dev/null 2>&1; }

echo "date_utc: $(date -u +%FT%TZ)"
mk netpol-intruder intruder; mk netpol-allowed write-probe
kubectl -n "$NS" wait --for=condition=Ready pod/netpol-intruder pod/netpol-allowed --timeout=90s >/dev/null 2>&1 || { echo "test pods not ready, stop"; exit 2; }

PG=pg-ha-0.pg-ha-headless.pg-ha.svc.cluster.local
OS=objstore.pg-ha.svc.cluster.local
GF=grafana.pg-ha.svc.cluster.local

if reach netpol-intruder "$GF" 3000; then ok "control: the intruder pod reaches Grafana on 3000"; else bad "control: the intruder pod reaches Grafana on 3000"; echo "controls failed, stop"; exit 2; fi
if reach netpol-intruder "$GF" 9; then bad "control: a closed port reads as open"; echo "controls failed, stop"; exit 2; else ok "control: a closed port reads as blocked"; fi

if [ -s k8s/pg/70-networkpolicy.yaml ]; then ok "k8s/pg/70-networkpolicy.yaml exists"; else bad "k8s/pg/70-networkpolicy.yaml exists"; fi
n=$(kubectl -n "$NS" get networkpolicy --no-headers 2>/dev/null | wc -l)
if [ "$n" -ge 2 ]; then ok "$n NetworkPolicies exist in pg-ha"; else bad "at least 2 NetworkPolicies exist in pg-ha (found $n)"; fi

if reach netpol-intruder "$PG" 5432; then bad "intruder is blocked from pg-ha-0 on 5432"; else ok "intruder is blocked from pg-ha-0 on 5432"; fi
if reach netpol-intruder "$PG" 8008; then bad "intruder is blocked from pg-ha-0 on 8008"; else ok "intruder is blocked from pg-ha-0 on 8008"; fi
if reach netpol-intruder "$OS" 3900; then bad "intruder is blocked from objstore on 3900"; else ok "intruder is blocked from objstore on 3900"; fi

if reach netpol-allowed "$PG" 5432; then ok "app=write-probe reaches pg-ha-0 on 5432"; else bad "app=write-probe reaches pg-ha-0 on 5432"; fi
if py pg-ha pg-ha-0 "$OS" 3900; then ok "pg-ha-0 reaches objstore on 3900"; else bad "pg-ha-0 reaches objstore on 3900"; fi
if py pg-restore pg-restore-0 "$OS" 3900; then ok "pg-restore-0 reaches objstore on 3900"; else bad "pg-restore-0 reaches objstore on 3900"; fi

up=$(kubectl -n "$NS" exec pg-ha-0 -c postgres -- python3 -c 'import urllib.request as u,json;t=json.load(u.urlopen("http://prometheus.pg-ha.svc.cluster.local:9090/api/v1/targets?state=active",timeout=8))["data"]["activeTargets"];print(sum(1 for x in t if x["health"]=="up"))' 2>/dev/null || true)
if [ "${up:-0}" = 8 ]; then ok "Prometheus has 8 targets up"; else bad "Prometheus has 8 targets up (found ${up:-0})"; fi
if wait_healthy 60; then ok "Patroni is 1 leader + 2 streaming replicas"; else bad "Patroni is 1 leader + 2 streaming replicas"; fi
exit "$fail"
