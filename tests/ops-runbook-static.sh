#!/usr/bin/env bash
# OPS-3 (static): docs/runbook.md has the switchover and minor-version upgrade runbooks with the real commands.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
r=docs/runbook.md
fail=0
pass() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
echo "date_utc: $(date -u +%FT%TZ)"
sec() { awk -v h="$1" '$0==h{f=1;next} /^## /{f=0} f' "$r"; }
has() { # description heading pattern
  if sec "$2" | grep -qE -- "$3"; then pass "$1"; else bad "$1"; fi
}
if [ "$(grep -cxF '## Restore' "$r")" = 1 ]; then pass "control: the Restore section is found"; else bad "control: the Restore section is found"; fi
for h in '## Planned switchover' '## Minor-version upgrade'; do
  if [ "$(grep -cxF "$h" "$r")" = 1 ]; then pass "section exists: $h"; else bad "section exists: $h"; fi
done
S='## Planned switchover'; U='## Minor-version upgrade'
has "switchover: patronictl switchover" "$S" 'patronictl .*switchover'
has "switchover: write probe" "$S" 'tests/lib/probe\.sh'
has "switchover: patronictl list" "$S" 'patronictl .*list'
has "switchover: TLS check" "$S" 'tests/sec-tls\.sh'
has "switchover: timeline" "$S" '[Tt]imeline'
has "switchover: rollback" "$S" '[Rr]ollback'
has "upgrade: versions.env" "$U" 'versions\.env'
has "upgrade: image build" "$U" 'image-build\.sh'
has "upgrade: kind load by name:tag" "$U" 'kind load docker-image'
has "upgrade: rollout status" "$U" 'rollout status'
has "upgrade: write probe" "$U" 'tests/lib/probe\.sh'
has "upgrade: rollback" "$U" '[Rr]ollback'
exit "$fail"
