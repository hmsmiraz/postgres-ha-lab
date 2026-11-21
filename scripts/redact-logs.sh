#!/usr/bin/env bash
# Redact secret-shaped values from raw AI session logs (the rules live in scripts/redact.pl).
# The line count is preserved, so
#   diff docs/ai-process/raw/X docs/ai-process/redacted/X
# shows exactly which lines were touched. Raw files are never modified.
set -euo pipefail

RAW=${RAW_DIR:-docs/ai-process/raw}
OUT=${OUT_DIR:-docs/ai-process/redacted}
MANIFEST="$OUT/MANIFEST.tsv"

mkdir -p "$OUT"
printf 'file\traw_sha256\tredacted_sha256\tlines_changed\trules_applied\n' > "$MANIFEST"

shopt -s nullglob
for f in "$RAW"/*; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  out="$OUT/$name"
  rules=$(perl scripts/redact.pl "$f" 2>&1 >"$out")
  changed=$(diff "$f" "$out" | grep -c '^<' || true)
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" \
    "$(sha256sum "$f" | cut -d' ' -f1)" \
    "$(sha256sum "$out" | cut -d' ' -f1)" "$changed" "${rules:-none}" >> "$MANIFEST"
  echo "redacted $name: $changed line(s) changed (${rules:-no rule fired})"
done
