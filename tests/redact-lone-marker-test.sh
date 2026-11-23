#!/usr/bin/env bash
# Test: a private-key BEGIN marker without an END marker must not redact the ordinary lines that follow it.
# A complete block and a truncated key (base64 body, no END) are still redacted. Markers and bodies are
# assembled at run time, so this file holds no key block.
set -euo pipefail
cd "$(dirname "$0")/.."

fails=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT

begin=$(printf '%s %s %s' '-----BEGIN' 'RSA PRIVATE' 'KEY-----')
end=$(printf '%s %s %s' '-----END' 'RSA PRIVATE' 'KEY-----')
b1=$(printf '%s%s' 'Zm9vYmFy' 'YmF6cXV4')
b2=$(printf '%s%s' 'cXV1eGNv' 'cmdlZ3Jh')
p1='ordinary line one with spaces'
p2='export FOO=bar and more words'
p3='last ordinary line'

printf '%s\n' "$p1" "$begin" "$p2" "$p3" "$p1" > "$D/A.in"
printf '%s\n' "$p1" "$begin" "$b1" "$b2" "$p2" "$p3" > "$D/B.in"
printf '%s\n' "$p1" "$begin" "$b1" "$b2" "$end" "$p2" > "$D/C.in"

# Print the numbers of the lines that differ between two files, separated by spaces.
changed_lines() {
  awk 'NR==FNR{a[NR]=$0;next}{if(a[FNR]!=$0)printf "%s%d",(s++?" ":""),FNR}' "$1" "$2"
}

check() { # name, expected changed lines, body line to look for (or empty)
  local name=$1 want=$2 body=$3 got n
  [ -s "$D/$name.in" ] || { bad "$name: input is empty"; return; }
  perl scripts/redact.pl "$D/$name.in" > "$D/$name.out" 2>/dev/null
  if [ "$(wc -l < "$D/$name.in")" = "$(wc -l < "$D/$name.out")" ]; then
    ok "$name: line count unchanged"
  else
    bad "$name: line count changed"
  fi
  got=$(changed_lines "$D/$name.in" "$D/$name.out")
  if [ "$got" = "$want" ]; then
    ok "$name: changed lines are '$want'"
  else
    bad "$name: changed lines are '$got', expected '$want'"
  fi
  if [ -n "$body" ]; then
    n=$(grep -cF -- "$body" "$D/$name.out" || true)
    if [ "$n" = 0 ]; then ok "$name: base64 body is gone"; else bad "$name: base64 body survives ($n lines)"; fi
  fi
}

check A "2" ""
check B "2 3 4" "$b1"
check C "2 3 4 5" "$b1"

# Negative control: the comparer reports nothing for identical files and sees a one-line change.
if [ -z "$(changed_lines "$D/A.in" "$D/A.in")" ]; then ok "control: identical files report no change"; else bad "control: identical files report a change"; fi
sed '1s/.*/x/' "$D/A.in" > "$D/A.mod"
if [ "$(changed_lines "$D/A.in" "$D/A.mod")" = "1" ]; then ok "control: a one-line change is seen"; else bad "control: a one-line change is not seen"; fi

echo "redact-lone-marker-test: $fails failed"
[ "$fails" -eq 0 ]
