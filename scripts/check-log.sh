#!/usr/bin/env bash
# Completeness check for a captured chat log. Prints counts only, never chat text.
# Exit code 1 if any section heading of the assistant's replies is missing.
set -euo pipefail
F=${1:?usage: scripts/check-log.sh <file>}
missing=0
wc -l -c "$F"
markers=(
  "What they want, in short"
  "Best practices for this task"
  "Plan before we start"
  "Phase 1, step 1: pin versions"
  "Phase 1, step 1: session log redaction"
  "Phase 2, step 1: kind cluster"
  "Phase 2, step 2: the image"
  "Phase 2, step 3: deploy Patroni"
  "Phase 2, step 4: the first failover test"
  "Phase 2, step 5: node loss"
  "Phase 2, step 6: storage loss"
  "Phase 2, step 7: split-brain"
  "Phase 2, step 8: FO-5"
  "Phase 2, step 9: REP-3 drill"
  "Phase 2, step 10: degraded synchronous mode"
  "Phase 2, last step: placement"
  "Phase 2 summary"
)
for m in "${markers[@]}"; do
  n=$(grep -cE -- "^[[:space:]]*${m}" "$F" || true)
  printf '%-46s %s\n' "$m" "$n"
  if [ "$n" -lt 1 ]; then missing=$((missing + 1)); fi
done
echo "lines with the user's terminal prompt: $(grep -c 'hmsmiraz@HMSMIRAZ' "$F" || true)"
echo "mentions of the brief title: $(grep -c 'Take-Home Assignment' "$F" || true)"
echo "headings missing: $missing"
[ "$missing" -eq 0 ]
