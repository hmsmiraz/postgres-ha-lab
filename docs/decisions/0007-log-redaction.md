# ADR-0007: log redaction treats a lone private-key marker as a single line

Status: Accepted (Phase 4). Changes scripts/redact.pl. Adds tests/redact-lone-marker-test.sh. tests/redact-test.sh is unchanged.

## Context
scripts/redact.pl replaces secret-shaped values in AI session logs, line by line. For a private-key block it started at a
BEGIN marker line and stopped only at an END marker line. The raw capture of the second phase 3 chat holds one planted test
marker (line 639) with no END marker. Everything after it was treated as key text: 13110 of 13748 lines were replaced, so the
redacted copy was unusable and was not committed.

## Options
1. Fix the rule, test first, regenerate the log, commit it (chosen by the human: "A").
2. Edit the raw file by hand. Rejected: raw logs are never edited.
3. Drop the capture. Not chosen.
Rule options: R1, a block counts only if an END marker follows within a fixed number of lines (needs two passes, and a truncated real
key would leak its body). R2, inside a block a line stays in the block only if it is base64 text, a PEM header line, or an END
marker; the first other line ends the block and is processed normally (one pass). The human chose R2 and a new test file (T1).

## Decision
R2. In scripts/redact.pl, an open block is closed by the first line that is not base64 text of 4 or more characters, not a
Proc-Type or DEK-Info line, and not a marker. The line that closes the block is then processed by the normal rules.
tests/redact-lone-marker-test.sh builds markers and bodies from pieces, so the test file holds no key block. Cases: A, a lone
marker followed by ordinary lines (only the marker line changes); B, a truncated key (marker and two base64 lines, no END; those
3 lines change, the ordinary lines after them do not); C, a complete block (4 lines change). It also checks that the input is
non-empty, that the line count is unchanged, that no base64 body survives in B and C, and a negative control for the line comparer.

## Evidence
- docs/evidence/REDACT-lone-marker-FAILED.txt: the test before the fix, 2 FAIL lines (cases A and B), as intended.
- docs/evidence/REDACT-lone-marker.txt: the test after the fix, 0 failed, and the unchanged tests/redact-test.sh, all checks passed.
- Regenerated phase 3 chat log: 13748 lines in and out, 1 line changed (the marker line), 0 BEGIN markers left, gitleaks found no leaks.
  The 2026-11-20 redacted log is byte-identical to its committed version.

## Consequences
- The redacted log of the second phase 3 chat can be committed and is.
- A line that is a single plain word of 4 or more letters directly after a lone marker is treated as key text and replaced, until the
  first other line.
- An encrypted key whose body follows a blank line is not fully covered: the blank line closes the block, so the body is not redacted.
  Not tested.

## Not verified
Other secret shapes in the chat logs (the limits in docs/ai-process/LOGGING.md still apply), binary content, and the rule on logs
other than the two captured so far.
