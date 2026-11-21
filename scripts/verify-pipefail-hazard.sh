#!/usr/bin/env bash
# Shows that "producer | grep -q" can miss a planted secret under pipefail (the producer dies of SIGPIPE and the
# pipeline status becomes non-zero), and that "grep -c" does not. The effect is a race, so five trials are run.
set -uo pipefail
secret="HAZARDTEST-$(openssl rand -hex 12)"
pat=$(mktemp)
printf '%s\n' "$secret" >"$pat"
trap 'rm -f "$pat"' EXIT
producer() { echo "$secret"; yes filler | head -n 1000000; }
echo "date_utc: $(date -u +%FT%TZ)"
missed=0
found_c=0
for _ in 1 2 3 4 5; do
  if producer | grep -F -q -f "$pat"; then :; else missed=$((missed + 1)); fi
  n=$(producer | grep -F -c -f "$pat" || true)
  if [ "${n:-0}" -ge 1 ]; then found_c=$((found_c + 1)); fi
done
echo "RESULT q-form: reported 'no match' for a planted secret in $missed of 5 trials"
echo "RESULT c-form: found the planted secret in $found_c of 5 trials"
if [ "$missed" -gt 0 ]; then
  echo "RESULT hazard: OBSERVED. A leak check written as 'producer | grep -q' can miss a leak."
else
  echo "RESULT hazard: not observed in these trials. It is a race and a slower producer (kubectl) may still trigger it; the c-form is used anyway."
fi
