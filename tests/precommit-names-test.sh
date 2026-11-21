#!/usr/bin/env bash
# Test: the pre-commit hook blocks staged lines with a forbidden identifier and lets clean ones through.
# Runs in a throwaway repository; the forbidden name is assembled at run time.
set -euo pipefail
cd "$(dirname "$0")/.."
HOOK=$PWD/.githooks/pre-commit
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }

D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
cd "$D"
git init -q
git config user.email t@example.com
git config user.name t
name=$(printf '%s%s' clou dly)

echo "hello world" > ok.txt
git add ok.txt
bash "$HOOK" >/dev/null 2>&1 || fail "the hook blocked a clean change"
pass "a clean change passes"

echo "mail ops@${name}.io" > bad.txt
git add bad.txt
if bash "$HOOK" >/dev/null 2>&1; then fail "the hook let a forbidden identifier through"; fi
pass "a staged line with a forbidden identifier is blocked"

git reset -q
echo "[REDACTED:company]" > redacted.txt
git add redacted.txt
bash "$HOOK" >/dev/null 2>&1 || fail "the hook blocked the redaction marker"
pass "the redaction marker passes"
echo "ALL CHECKS PASSED"
