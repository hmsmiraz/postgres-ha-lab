#!/usr/bin/env bash
# Controls for the secret-leak checks used in tests/obj-s3.sh. The test values are random at run time,
# so they appear in no file of the repo. (The first version of this check hard-coded them in its own
# script, and both of its controls were invalid.)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
tmp=$(mktemp -d)
planted=""
cleanup() {
  rm -rf "$tmp"
  if [ -n "$planted" ]; then rm -f "$planted"; fi
}
trap cleanup EXIT
res() { echo "RESULT $1: $2"; }

secret="LEAKTEST-$(openssl rand -hex 12)"
absent="LEAKTEST-$(openssl rand -hex 12)"
printf '%s\n' "$secret" >"$tmp/pat-present.txt"
printf '%s\n' "$absent" >"$tmp/pat-absent.txt"

echo "date_utc: $(date -u +%FT%TZ)"
if git grep --untracked -I -F -q -f "$tmp/pat-present.txt"; then
  res git-grep-before-planting "FAIL, fired before the value was planted"
else
  res git-grep-before-planting "OK, silent"
fi
planted=$(mktemp -p . leakprobe.XXXXXX)
printf 'harmless text %s harmless\n' "$secret" >"$planted"
if git grep --untracked -I -F -q -f "$tmp/pat-present.txt"; then
  res git-grep-positive "OK, fires on the planted value"
else
  res git-grep-positive "FAIL, did not fire"
fi
if git grep --untracked -I -F -q -f "$tmp/pat-absent.txt"; then
  res git-grep-negative "FAIL, false positive"
else
  res git-grep-negative "OK, silent for a value that is not there"
fi
rm -f "$planted"
planted=""
if git grep --untracked -I -F -q -f "$tmp/pat-present.txt"; then
  res git-grep-after-removal "FAIL, still fires"
else
  res git-grep-after-removal "OK, silent again"
fi

if printf 'log line with %s inside\n' "$secret" | grep -F -q -f "$tmp/pat-present.txt"; then
  res log-grep-positive "OK, fires"
else
  res log-grep-positive "FAIL"
fi
if printf 'log line without it\n' | grep -F -q -f "$tmp/pat-present.txt"; then
  res log-grep-negative "FAIL, false positive"
else
  res log-grep-negative "OK, silent"
fi
printf '\n' >"$tmp/pat-empty-line.txt"
if printf 'any text\n' | grep -F -q -f "$tmp/pat-empty-line.txt"; then
  res empty-pattern-hazard "CONFIRMED: an empty line in a pattern file matches everything, so obj-s3.sh must keep its non-empty checks"
else
  res empty-pattern-hazard "not observed"
fi
echo "LEAK DETECTOR CHECKS DONE"
