#!/usr/bin/env bash
# Redact secrets from raw AI session logs.
# Only secrets are replaced. The line count is preserved, so
#   diff docs/ai-process/raw/X docs/ai-process/redacted/X
# shows exactly which lines were touched.
set -euo pipefail

RAW=docs/ai-process/raw
OUT=docs/ai-process/redacted
MANIFEST="$OUT/MANIFEST.tsv"

mkdir -p "$OUT"
printf 'file\traw_sha256\tredacted_sha256\tlines_redacted\n' > "$MANIFEST"

shopt -s nullglob
for f in "$RAW"/*; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  out="$OUT/$name"
  sed -E \
    -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/ s/.*/[REDACTED:private-key-line]/' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED:aws-access-key-id]/g' \
    -e 's/(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{20,})/[REDACTED:github-token]/g' \
    -e 's/xox[abprs]-[A-Za-z0-9-]{10,}/[REDACTED:slack-token]/g' \
    -e 's/(Bearer )[A-Za-z0-9._~+\/=-]{20,}/\1[REDACTED:bearer-token]/g' \
    -e 's#(://[^:/@[:space:]]+:)[^@[:space:]]+@#\1[REDACTED:uri-password]@#g' \
    -e 's/((password|passwd|secret|token|api[_-]?key|access[_-]?key)[[:space:]]*[=:][[:space:]]*)[^[:space:]]+/\1[REDACTED:value]/Ig' \
    "$f" > "$out"
  changed=$(diff "$f" "$out" | grep -c '^<' || true)
  printf '%s\t%s\t%s\t%s\n' "$name" \
    "$(sha256sum "$f" | cut -d' ' -f1)" \
    "$(sha256sum "$out" | cut -d' ' -f1)" "$changed" >> "$MANIFEST"
  echo "redacted $name: $changed line(s) changed"
done
