#!/usr/bin/env bash
# Item 45 (documented restore procedure): docs/runbook.md holds a "## Restore" section built from RS-1 to RS-3 and BK-2 to BK-4.
# This is a static check that the document does not contradict the repository; it does not prove that the steps work (the restore
# tests do). Checked: planted-input controls for every checker; the file and exactly one "## Restore" heading; the section is not
# trivially short; 15 required topics are mentioned; every path named (scripts/, k8s/, tests/, docs/) exists and at least 10 are
# named; every RESTORE_* variable named appears in a script and at least 6 are named; no TODO, FIXME or <placeholder>; no match of
# the pre-commit hook's pattern (count only); no live secret value (read-only cluster reads, the scanner fires on planted input first).
# The section must not use wildcards in paths. Not covered: that the commands work, the wording, the order of the steps.
# Leak scans use grep -c, never "producer | grep -q".
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source tests/lib/probe.sh

DOC=docs/runbook.md
REQ=(scripts/restore-full.sh scripts/restore-down.sh scripts/restore-test.sh RESTORE_TARGET RESTORE_TYPE RESTORE_TARGET_ACTION
  RESTORE_TEST_SQL RESTORE_TEST_EXPECT docs/evidence/RS-1.txt docs/evidence/RS-2.txt docs/evidence/RS-3.txt
  docs/known-limitations.md docs/decisions/0006-restore-design.md archive_mode retention)
k() { kubectl -n "$NS" "$@"; }

umask 077
work=$(mktemp -d)
# shellcheck disable=SC2329
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

section() { awk '/^## Restore$/ { on = 1; next } on && /^## / { exit } on { print }' "$1"; }
paths_of() { { grep -o -E '(scripts|k8s|tests|docs)/[A-Za-z0-9_./-]+' || true; } | sed -E 's/[.,]+$//' | sort -u; }
count_paths() { paths_of <<<"$1" | grep -c . || true; }
missing_paths() {
  local p n=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -e "$p" ] || n=$((n + 1))
  done < <(paths_of <<<"$1")
  echo "$n"
}
vars_of() { { grep -o -E 'RESTORE_[A-Z_]+' || true; } | sort -u; }
count_vars() { vars_of <<<"$1" | grep -c . || true; }
missing_vars() {
  local v n=0
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    [ "$(grep -r -l -F -- "$v" scripts | wc -l)" -ge 1 ] || n=$((n + 1))
  done < <(vars_of <<<"$1")
  echo "$n"
}
mentions_missing() {
  local m n=0
  for m in "${REQ[@]}"; do
    [ "$(grep -c -E -- "(^|[^A-Za-z0-9_])${m}([^A-Za-z0-9_]|\$)" <<<"$1" || true)" -ge 1 ] || n=$((n + 1))
  done
  echo "$n"
}
placeholders() { grep -c -E 'TODO|FIXME|<[A-Za-z_][A-Za-z0-9_-]*>' <<<"$1" || true; }

echo "date: $(date -u +%FT%TZ)"
c1="x tests/lib/probe.sh y"
{ [ "$(count_paths "$c1")" = 1 ] && [ "$(missing_paths "$c1")" = 0 ]; } || fail "control: the path checker does not accept an existing path"
[ "$(missing_paths "x scripts/no-such-file.sh y")" = 1 ] || fail "control: the path checker does not catch a missing path"
[ "$(missing_vars "use RESTORE_TARGET here")" = 0 ] || fail "control: the variable checker does not accept a known variable"
[ "$(missing_vars "use RESTORE_NO_SUCH_VAR here")" = 1 ] || fail "control: the variable checker does not catch an unknown variable"
[ "$(mentions_missing "nothing here")" = "${#REQ[@]}" ] || fail "control: the mention checker does not report all ${#REQ[@]} topics missing for an empty text"
[ "$(placeholders "run <name> now")" = 1 ] || fail "control: the placeholder checker does not catch a placeholder"
[ "$(placeholders "run it now")" = 0 ] || fail "control: the placeholder checker flags a clean line"
printf '%s\n' '## Other' 'x' '## Restore' 'body1' 'body2' '## Next' 'y' >"$work/sec.md"
[ "$(section "$work/sec.md" | tr '\n' ' ')" = "body1 body2 " ] || fail "control: the section extractor does not return exactly the Restore section"
pass "controls: every checker accepts a good case and catches a bad one (planted input)"

[ -f "$DOC" ] || fail "docs/runbook.md does not exist"
[ "$(grep -c -x '## Restore' "$DOC" || true)" = 1 ] || fail "docs/runbook.md must hold exactly one '## Restore' heading"
sec=$(section "$DOC")
[ "$(grep -c '' <<<"$sec")" -ge 20 ] || fail "the Restore section has fewer than 20 lines"
pass "docs/runbook.md exists with one Restore section of $(grep -c '' <<<"$sec") lines"

mm=$(mentions_missing "$sec")
[ "$mm" = 0 ] || fail "$mm of ${#REQ[@]} required topics are not mentioned in the Restore section"
pass "all ${#REQ[@]} required topics are mentioned"

np=$(count_paths "$sec")
echo "INFO: paths named: $np"
[ "$np" -ge 10 ] || fail "fewer than 10 paths are named in the Restore section"
mp=$(missing_paths "$sec")
[ "$mp" = 0 ] || fail "$mp path(s) named in the Restore section do not exist"
nv=$(count_vars "$sec")
echo "INFO: RESTORE_* variables named: $nv"
[ "$nv" -ge 6 ] || fail "fewer than 6 RESTORE_* variables are named in the Restore section"
mv=$(missing_vars "$sec")
[ "$mv" = 0 ] || fail "$mv variable(s) named in the Restore section appear in no script"
[ "$(placeholders "$sec")" = 0 ] || fail "the Restore section holds a TODO, FIXME or <placeholder>"
pass "every named path exists, every named RESTORE_* variable is in a script, and there is no placeholder"

line=$(grep -E '^pat=' .githooks/pre-commit || true)
{ [ -n "$line" ] && [ "$(grep -c '' <<<"$line")" = 1 ]; } || fail "expected exactly one pat= line in the hook"
pat=""
eval "$line"
[ -n "$pat" ] || fail "the evaluated hook pattern is empty"
IFS='|' read -r -a alts <<<"$pat"
fired=0
for a in "${alts[@]}"; do
  [ -n "$a" ] || continue
  if [ "$(printf '%s\n' "$a" | grep -c -i -E "$pat" || true)" -ge 1 ]; then fired=$((fired + 1)); fi
done
[ "$fired" -ge 1 ] || fail "control: the hook pattern does not match its own alternatives, so the scan would prove nothing"
hits=$(grep -c -i -E "$pat" "$DOC" || true)
[ "${hits:-0}" = 0 ] || fail "docs/runbook.md holds $hits line(s) that match the pre-commit hook's pattern"
pass "no line of docs/runbook.md matches the pre-commit hook's pattern (control: the pattern matches $fired of ${#alts[@]} of its own alternatives)"

sk=$(k get secret objstore-credentials -o json | jq -r '.data["secret-access-key"] // empty' | base64 -d)
pw=$(k get secret pg-credentials -o json | jq -r '.data["superuser-password"] // empty' | base64 -d)
[ -n "$sk" ] || fail "the secret access key could not be read"
[ -n "$pw" ] || fail "the superuser password could not be read"
printf '%s\n%s\n' "$sk" "$pw" >"$work/secrets"
[ "$(grep -F -c -f "$work/secrets" <<<"control line with $sk inside" || true)" -eq 1 ] || fail "control: the scanner did not fire on a planted secret key"
[ "$(grep -F -c -f "$work/secrets" <<<"control line with $pw inside" || true)" -eq 1 ] || fail "control: the scanner did not fire on a planted password"
[ "$(grep -F -c -f "$work/secrets" "$DOC" || true)" -eq 0 ] || fail "a live secret value appears in docs/runbook.md"
pass "no live secret value in docs/runbook.md (the scanner fired on planted input first)"
echo "ALL CHECKS PASSED"
