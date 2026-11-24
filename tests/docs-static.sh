#!/usr/bin/env bash
# DOC-1 (static): docs/design.md and README.md hold the required statements; links and images resolve; no forbidden name.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
pass() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
echo "date_utc: $(date -u +%FT%TZ)"
d=docs/design.md; r=README.md
if [ -s "$d" ]; then pass "$d exists"; else bad "$d exists"; fi
h() { if [ "$(grep -cxF -- "$2" "$d" 2>/dev/null || true)" = 1 ]; then pass "design.md has: $1"; else bad "design.md has: $1"; fi; }
h "sync vs async and RPO" "## 1. Synchronous replication and RPO"
h "fencing and leader election" "## 2. Fencing and leader election"
h "measured RTO and method" "## 3. Measured RTO and method"
h "multi-zone changes" "## 4. What changes on a real multi-zone cluster"
h "generalisation" "## 5. Generalisation"
h "determinism" "## 6. Determinism"
h "agent-agnostic" "## 7. Agent-agnostic"
h "threat model" "## 8. Threat model"
h "AI process" "## 9. AI process"
n=$(grep -c '6731' "$d" 2>/dev/null || true); if [ "${n:-0}" -ge 1 ]; then pass "design.md quotes the FO-1 RTO 6731 ms"; else bad "design.md quotes the FO-1 RTO 6731 ms"; fi
n=$(grep -c '33420' "$d" 2>/dev/null || true); if [ "${n:-0}" -ge 1 ]; then pass "design.md quotes the FO-2 RTO 33420 ms"; else bad "design.md quotes the FO-2 RTO 33420 ms"; fi
n=$(grep -c 'make up' "$r" 2>/dev/null || true); if [ "${n:-0}" -ge 1 ]; then pass "README has run instructions (make up)"; else bad "README has run instructions (make up)"; fi
n=$(grep -c 'docs/images/' "$r" 2>/dev/null || true); if [ "${n:-0}" -ge 4 ]; then pass "README shows all 4 screenshots"; else bad "README shows all 4 screenshots (found ${n:-0})"; fi
miss=0; cnt=0
for x in "$r" "$d"; do
  [ -s "$x" ] || continue
  dir=$(dirname "$x")
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    cnt=$((cnt + 1)); [ -e "$dir/$l" ] || { echo "  missing link target in $x: $l"; miss=$((miss + 1)); }
  done < <(grep -ohE '\]\([^)#]+\)' "$x" | sed -E 's/^\]\(//; s/\)$//' | grep -v -e '^http' | sort -u)
done
if [ "$cnt" -ge 8 ] && [ "$miss" = 0 ]; then pass "all $cnt relative links and images resolve"; else bad "relative links and images resolve (checked $cnt, missing $miss)"; fi
n1=$(printf '%s%s' rev ora); n2=$(printf '%s%s' clou dly); hits=0
for x in "$d" "$r"; do for nn in "$n1" "$n2"; do c=$(grep -ci -- "$nn" "$x" 2>/dev/null || true); hits=$((hits + ${c:-0})); done; done
if [ -s "$d" ] && [ "$hits" = 0 ]; then pass "no forbidden name in design.md and README.md"; else bad "forbidden name hits or missing file: $hits"; fi
ctl=$(mktemp); printf 'zzqx\n' > "$ctl"; n=$(grep -c zzqx "$ctl" || true); rm -f "$ctl"
if [ "${n:-0}" -eq 1 ]; then pass "control: the counter sees a known string"; else bad "control: the counter sees a known string"; fi
exit "$fail"
