# Session logging

## Rules
- Logs are saved verbatim in `docs/ai-process/raw/` (git-ignored). No edits, no summaries, no reconstruction.
- Only secrets are removed, by `scripts/redact-logs.sh`. The output goes to `docs/ai-process/redacted/` and is committed.
- `redacted/MANIFEST.tsv` records the SHA-256 of each raw and redacted file and the number of redacted lines.
- Line counts are preserved, so `diff raw/X redacted/X` shows only redacted lines.
- `gitleaks dir docs/ai-process/redacted` must report no leaks before committing.

## File naming
`YYYY-MM-DD-<tool>-<topic>.md`, for example `2026-11-19-claude-chat-setup.md`.

## What is captured
- Full chat text of every AI session that influenced the repo, saved at the end of each working session.
- Screenshots are not captured. Terminal output pasted into a chat is part of the text.

## Redaction limits
Pattern-based redaction cannot catch every secret, such as a password typed into the middle of a sentence. Secrets are never pasted into AI tools. The scripts only catch mistakes.
