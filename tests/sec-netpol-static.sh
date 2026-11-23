#!/usr/bin/env bash
# SEC-3 (static): k8s/pg/70-networkpolicy.yaml. Nothing is created in the cluster.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
p=k8s/pg/70-networkpolicy.yaml
fail=0
pass() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
echo "date_utc: $(date -u +%FT%TZ)"

res=$(python3 - "$p" <<'PY' 2>/dev/null
import sys, yaml
try:
    docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
except Exception:
    print("noparse"); sys.exit(0)
print("docs", len(docs))
names = sorted(d["metadata"]["name"] for d in docs if d.get("kind") == "NetworkPolicy")
print("names", ",".join(names))
print("ns", ",".join(sorted({d["metadata"].get("namespace", "") for d in docs})))
print("types", ",".join(sorted({",".join(d["spec"].get("policyTypes", [])) for d in docs})))
ports = sorted({str(pp["port"]) for d in docs for r in d["spec"].get("ingress", []) for pp in r.get("ports", [])})
print("ports", ",".join(ports))
print("ipblock", sum(1 for d in docs for r in d["spec"].get("ingress", []) for f in r.get("from", []) if "ipBlock" in f))
PY
)
g() { printf '%s\n' "$res" | sed -n "s/^$1 //p"; }

if [ -s "$p" ] && [ "$(g docs)" = 2 ]; then pass "file has 2 documents"; else bad "file has 2 documents"; fi
if [ "$(g names)" = "objstore-ingress,pg-ha-ingress" ]; then pass "policies are pg-ha-ingress and objstore-ingress"; else bad "policies are pg-ha-ingress and objstore-ingress"; fi
if [ "$(g ns)" = "pg-ha" ]; then pass "both policies are in pg-ha"; else bad "both policies are in pg-ha"; fi
if [ "$(g types)" = "Ingress" ]; then pass "policyTypes is Ingress only"; else bad "policyTypes is Ingress only"; fi
if [ "$(g ports)" = "3900,3903,5432,8008,8432,9187" ]; then pass "ports are 3900, 3903, 5432, 8008, 8432, 9187"; else bad "ports are 3900, 3903, 5432, 8008, 8432, 9187"; fi
if [ -s "$p" ] && [ "$(g ipblock)" = 0 ]; then pass "no ipBlock rule"; else bad "no ipBlock rule"; fi
n=$(grep -c '0\.0\.0\.0/0' "$p" 2>/dev/null || true)
if [ -s "$p" ] && [ "${n:-1}" = 0 ]; then pass "no 0.0.0.0/0"; else bad "no 0.0.0.0/0"; fi
n=$(grep -c 'kubernetes.io/metadata.name: pg-restore' "$p" 2>/dev/null || true)
if [ "${n:-0}" -ge 1 ]; then pass "objstore allows the pg-restore namespace"; else bad "objstore allows the pg-restore namespace"; fi

ctl=$(mktemp); printf 'zzqx\n' > "$ctl"
n=$(grep -c zzqx "$ctl" || true); rm -f "$ctl"
if [ "${n:-0}" -eq 1 ]; then pass "control: the counter sees a known string"; else bad "control: the counter sees a known string"; fi
exit "$fail"
