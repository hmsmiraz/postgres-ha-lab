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

## Capture of the Claude chat for phases 0 to 2 (2026-11-20)
- File: docs/ai-process/redacted/2026-11-20-claude-chat-share-copy.txt (9938 lines).
- Method: the claude.ai chat page cut long conversations, so the text was copied from the chat's
  read-only share page (snapshot refreshed first), with Ctrl+A and Ctrl+C, into a text file.
  Nothing was retyped, summarised or reordered.
- An earlier copy through a Google Doc (944 lines) missed most of the middle of the conversation.
  It was discarded and kept outside the repository; it is not part of the log.
- Cut-off: the log ends at the assistant's reply about the owner's company workspace (line 9936). Later
  messages, including the redaction rework, are not in this file; a later copy of the same chat
  will cover them.
- Not captured: screenshots. Terminal output the user pasted as text is included (188 lines
  carry the user's shell prompt).
- Completeness check: scripts/check-log.sh finds all 17 section headings of the assistant's replies.
- One hand edit, disclosed: after the capture, line 1331 (a made-up test key, invented for the
  redaction test) was changed by hand to "$value" so that gitleaks would not flag it. The raw file
  was 541096 bytes before, 541082 bytes after the edit, and 541096 bytes again after the line was
  restored from its known original. The restored file hashes to b674bfaf... (see MANIFEST.tsv). The
  hash was taken after the restore, so the byte counts are the evidence; no other byte changed.
  The raw file was made read-only afterwards.
- Raw logs are not committed (docs/ai-process/raw is git-ignored). MANIFEST.tsv holds the SHA-256
  of the raw and the redacted file.

## Redaction (scripts/redact.pl, tests/redact-test.sh)
- First version (broad rule on words like password and token): 22 lines changed, 19 of them false
  positives (variable references such as "$APP_PASSWORD", placeholders, prose, and the script's own
  source). That would have altered the transcript for no benefit, so the rules were narrowed.
- Current rules replace only values that look like secrets: AWS key ids, GitHub and Slack tokens,
  bearer tokens, passwords inside URLs, private key blocks, and values after words such as password
  or token that are 12 or more characters long and contain a digit. Variable references and
  placeholders are left alone. The line count never changes.
- Result on this log: 2 lines changed (1331 and 1332, both made-up test values); gitleaks found no
  leaks in the redacted copy.
- Limits: a real secret shorter than 12 characters, with no digit, or not next to one of those words
  would not be caught. Secrets are never pasted into AI tools; the database credentials in this
  project are generated at deploy time and never printed.
- Second redaction pass (2026-11-21): the assistant's replies named the owner's employer and its
  group mailbox, and the repository is public. A rule was added to scripts/redact.pl that replaces
  that company name, its domains and mail addresses with [REDACTED:company]. The pattern is
  assembled from pieces, so the script holds no company name, and tests/redact-test.sh covers it.
  The script applied it to the whole log; nothing was edited by hand. The raw hash is unchanged
  (see MANIFEST.tsv). The "2 changed lines" result above describes the first pass only.
- The branch was force-pushed once on 2026-11-21 to replace the commit that first added this log,
  because that commit still contained the company name. The replacement commit differs from it only
  by the new rule, its test, the regenerated redacted log and manifest, these notes, and one
  .gitignore line.
- Third redaction pass (2026-11-21): the log also contained the project name of the take-home
  assignment (it came from the user's folder name), and the repository is public. scripts/redact.pl
  now replaces it together with the employer's name, with the same rule and the same marker
  [REDACTED:company]; the pattern is assembled from pieces, and tests/redact-test.sh covers it.
  The script applied it to the whole log, not by hand; the raw hash is unchanged. The commits that
  first held the log were rewritten locally before the next push.
- The repository was deleted and created again on 2026-11-21, because GitHub kept serving earlier
  commits by their hash after two force-pushes. The new history is the locally rewritten one: the
  log and handoff commits were rebuilt on top of the last test commit, and no other commit changed.
