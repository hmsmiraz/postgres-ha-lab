#!/usr/bin/env bash
# Test: scripts/redact.pl removes secret-shaped values and company/project identifiers, and leaves
# variable references, placeholders and prose alone. Fake secrets and fake names are assembled at
# run time, so this file holds none of them.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }

D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT

aws="AKIA""ABCDEFGHIJKLMNOP"
pw=$(printf '%s%s' hunter 2pass)
val=$(printf '%s%s' a1b2c3d4 e5f6g7h8)
begin=$(printf '%s %s' '-----BEGIN' 'RSA PRIVATE KEY-----')
end=$(printf '%s %s' '-----END' 'RSA PRIVATE KEY-----')
org=$(printf '%s%s' clou dly)
proj=$(printf '%s%s' rev ora)
mailbox="devops@${org}.io"

# shellcheck disable=SC2016
printf '%s\n' \
  "hello world" \
  "export AWS_ACCESS_KEY_ID=$aws" \
  "db: postgres://app:$pw@db.example:5432/app" \
  "api_key=$val" \
  'PGPASSWORD="$APP_PASSWORD" psql -h x' \
  '--from-file=app-password=<(gen)' \
  'superuser-password: "$(gen)"' \
  "CREATE ROLE app LOGIN PASSWORD :'app_pw';" \
  'shows [sudo: authenticate] Password: with no progress after it' \
  "-e 's#(://[^:/@[:space:]]+:)[^@[:space:]]+@#x#g'" \
  "normal line" \
  "$begin" "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC" "$end" \
  "last line" \
  "write to ${mailbox} about the ${org^} workspace (${org}.com.bd)" \
  "see ai.${org}.io and ${org^}'s pages." \
  "my folder is /mnt/c/I/Projects/${proj^} Task and ${proj} too" > "$D/in.txt"

perl scripts/redact.pl "$D/in.txt" > "$D/out.txt" 2> "$D/rules.txt"

[ "$(wc -l < "$D/in.txt")" = "$(wc -l < "$D/out.txt")" ] || fail "the line count changed"
pass "line count is unchanged"

changed=$(awk 'NR==FNR { a[FNR]=$0; next } a[FNR] != $0 { printf "%s ", FNR }' "$D/in.txt" "$D/out.txt")
[ "$changed" = "2 3 4 12 13 14 16 17 18 " ] || fail "changed lines were: $changed (expected: 2 3 4 12 13 14 16 17 18)"
pass "only the intended lines changed (secrets, the 3-line key block, the 3 name lines)"

for s in "$aws" "$pw" "$val" MIIEvQIBADANBgkqhkiG9w0BAQEFAASC; do
  if grep -qF -- "$s" "$D/out.txt"; then fail "a fake secret value is still in the output"; fi
done
pass "no fake secret value is left in the output"
if grep -qi -- "$org" "$D/out.txt"; then fail "the company name is still in the output"; fi
if grep -qi -- "$proj" "$D/out.txt"; then fail "the project name is still in the output"; fi
pass "no company or project name is left in the output"

grep -q 'AWS_ACCESS_KEY_ID=\[REDACTED:aws-access-key-id\]' "$D/out.txt" || fail "missing the aws marker"
grep -q 'app:\[REDACTED:uri-password\]@db.example' "$D/out.txt" || fail "missing the uri marker"
grep -q 'api_key=\[REDACTED:value\]' "$D/out.txt" || fail "missing the value marker"
[ "$(sed -n '16p' "$D/out.txt")" = "write to [REDACTED:company] about the [REDACTED:company] workspace ([REDACTED:company])" ] || fail "line 16 was not redacted as expected"
[ "$(sed -n '17p' "$D/out.txt")" = "see [REDACTED:company] and [REDACTED:company]'s pages." ] || fail "line 17 was not redacted as expected"
[ "$(sed -n '18p' "$D/out.txt")" = "my folder is /mnt/c/I/Projects/[REDACTED:company] Task and [REDACTED:company] too" ] || fail "line 18 was not redacted as expected"
pass "markers are in place and the surrounding text is untouched"

printf 'api_key=%s\r\nplain\r\n' "$val" > "$D/crlf.txt"
perl scripts/redact.pl "$D/crlf.txt" > "$D/crlf.out" 2>/dev/null
[ "$(grep -c $'\r' "$D/crlf.out")" = 2 ] || fail "CRLF line endings were not preserved"
pass "CRLF line endings are preserved"
echo "ALL CHECKS PASSED"
