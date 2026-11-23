#!/usr/bin/env bash
# SEC-5: non-root, dropped capabilities, no privilege escalation, seccomp, restricted Pod Security.
# Live, read only: reads pods, and one server-side dry-run of a privileged pod that must be rejected.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
ok() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }

# JSON pod list on stdin -> one line per violation: ns/pod/container: what
violations() {
  jq -r '.items[] | . as $p | ($p.spec.securityContext // {}) as $ps
    | (($p.spec.containers // []) + ($p.spec.initContainers // []))[] | . as $c | ($c.securityContext // {}) as $cs
    | [
        (if (($cs.runAsNonRoot // $ps.runAsNonRoot // false) == true) or ((($cs.runAsUser // $ps.runAsUser // 0)) > 0) then empty else "not non-root" end),
        (if ($cs | has("allowPrivilegeEscalation")) and ($cs.allowPrivilegeEscalation == false) then empty else "privilege escalation allowed" end),
        (if (($cs.capabilities.drop // []) | index("ALL")) != null then empty else "capabilities not dropped" end),
        (if (($cs.seccompProfile.type // $ps.seccompProfile.type // "") == "RuntimeDefault") then empty else "seccomp not RuntimeDefault" end)
      ][] as $v | "\($p.metadata.namespace)/\($p.metadata.name)/\($c.name): \($v)"'
}

echo "date_utc: $(date -u +%FT%TZ)"

syn='{"items":[{"metadata":{"namespace":"x","name":"p"},"spec":{"containers":[{"name":"c","securityContext":{"privileged":true}}]}}]}'
nsyn=$(printf '%s' "$syn" | violations | wc -l)
if [ "$nsyn" -eq 4 ]; then ok "control: the checker reports 4 violations for a synthetic bad container"; else bad "control: the checker reports 4 violations for a synthetic bad container (found $nsyn)"; fi

for ns in pg-ha pg-restore; do
  lbl=$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)
  if [ "$lbl" = restricted ]; then ok "namespace $ns enforces restricted"; else bad "namespace $ns enforces restricted (label: '${lbl:-none}')"; fi
  json=$(kubectl -n "$ns" get pods -o json 2>/dev/null)
  np=$(printf '%s' "$json" | jq '.items | length' 2>/dev/null || echo 0)
  nc=$(printf '%s' "$json" | jq '[.items[] | ((.spec.containers // []) + (.spec.initContainers // []))[]] | length' 2>/dev/null || echo 0)
  v=$(printf '%s' "$json" | violations)
  if [ "${np:-0}" -ge 1 ] && [ -z "$v" ]; then ok "$ns: $np pods, $nc containers, 0 violations"; else bad "$ns: $np pods, $nc containers, violations: $(printf '%s' "$v" | wc -l)"; printf '%s\n' "$v" | head -n 8; fi
done

priv=$(mktemp)
cat > "$priv" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: sec5-privileged-probe
  namespace: pg-ha
spec:
  containers:
    - name: c
      image: docker.io/library/busybox:1.37.0
      securityContext:
        privileged: true
        runAsUser: 0
YAML
out=$(kubectl apply --dry-run=server -f "$priv" 2>&1); rc=$?
rm -f "$priv"
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'violates PodSecurity'; then ok "control: a privileged pod is rejected by Pod Security admission"; else bad "control: a privileged pod is rejected by Pod Security admission (exit $rc)"; fi
exit "$fail"
