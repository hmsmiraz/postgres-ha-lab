#!/usr/bin/env bash
# SEC-1: no secret and no forbidden name in the repository history or the tracked files. Counts only.
# Reads the live Secrets into a mode-600 temp file and never prints a value.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
umask 077
fail=0
ok() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "date_utc: $(date -u +%FT%TZ)"

rc=0; gitleaks git --no-banner --redact --log-opts="--all" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then ok "gitleaks over all commits and refs: 0 leaks ($(git rev-list --all | wc -l) commits)"; else bad "gitleaks over all commits and refs (exit $rc)"; fi

mkdir "$work/tree"
git ls-files -z | tar --null -T - -cf - 2>/dev/null | tar -xf - -C "$work/tree"
rc=0; gitleaks dir "$work/tree" --no-banner --redact >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then ok "gitleaks over the tracked files: 0 leaks ($(git ls-files | wc -l) files)"; else bad "gitleaks over the tracked files (exit $rc)"; fi

n1=$(printf '%s%s' rev ora); n2=$(printf '%s%s' clou dly)
for n in "$n1" "$n2"; do
  hits=0
  for c in $(git rev-list --all); do if git grep -qiI -e "$n" "$c"; then hits=$((hits + 1)); fi; done
  msgs=$(git log --all -i --grep="$n" --oneline | wc -l)
  auth=$(git log --all --format='%an %ae %cn %ce' | grep -ci -- "$n" || true)
  if [ "$hits$msgs$auth" = "000" ]; then ok "forbidden name: 0 hits in content, messages and authors"; else bad "forbidden name: content $hits, messages $msgs, authors $auth"; fi
done

tr=$(git log --all --format=%B | grep -ci -e 'co-authored-by' -e 'contributor' || true)
if [ "$tr" = 0 ]; then ok "no co-author or contributor trailer"; else bad "trailer lines: $tr"; fi

: > "$work/values"
for pair in pg-credentials objstore-credentials objstore-admin grafana-admin; do
  kubectl -n pg-ha get secret "$pair" -o json 2>/dev/null | jq -r '.data[]? | @base64d' >> "$work/values" 2>/dev/null
done
total=$(grep -c . "$work/values" || true)
short=$(awk 'length($0) > 0 && length($0) < 8' "$work/values" | wc -l)
grep -v '^$' "$work/values" | awk 'length($0) >= 8' > "$work/pat"
if [ "$total" -ge 10 ] && [ "$short" -eq 0 ]; then ok "secret value list is usable ($total values, none short)"; else bad "secret value list is usable ($total values, $short short)"; fi
tf=$(git ls-files -z | xargs -0 grep -l -F -f "$work/pat" 2>/dev/null | wc -l)
hc=0
for c in $(git rev-list --all); do if git grep -q -F -f "$work/pat" "$c" 2>/dev/null; then hc=$((hc + 1)); fi; done
if [ "$tf" = 0 ] && [ "$hc" = 0 ]; then ok "no live secret value in tracked files (0) or in any commit (0)"; else bad "live secret values: tracked files $tf, commits $hc"; fi

mkdir "$work/plant"
tok=$(head -c 400 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 36)
printf 'token = %s%s\n' "ghp_" "$tok" > "$work/plant/a.txt"
rc=0; gitleaks dir "$work/plant" --no-banner --redact >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then ok "control: a planted token makes gitleaks fail"; else bad "control: a planted token was NOT detected"; fi
printf 'knownvalue12345\n' > "$work/p2"; printf 'xx knownvalue12345 yy\n' > "$work/t2"
if [ "$(grep -c -F -f "$work/p2" "$work/t2" || true)" = 1 ]; then ok "control: the value matcher finds a known string"; else bad "control: the value matcher finds a known string"; fi
exit "$fail"
