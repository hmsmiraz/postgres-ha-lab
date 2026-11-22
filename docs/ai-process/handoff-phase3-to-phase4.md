# Handoff: Phase 3 work is done and committed; the phase is not closed until the human says so (updated 2026-11-22)

Read AGENTS.md, SPEC.md and docs/decisions/ first. Work test-first; keep failed runs as evidence.
A new chat has only the repo files it is given and the human's opening message. "Estimate" means an estimate by the previous
assistant, in hours, not measured. "Prediction" means not verified.
A new chat starts by asking the human for "git log --oneline -5" and "git status --short".

## a) Current state
origin/main is fbec6a2 (pushed by the human on his own decision before the phase was done; not checked again since).
These commits are local only, oldest first: 4eb72a3 handoff, a874222 RS-2, a3054f0 RS-3 and the RS-3 SPEC line, 79e6b2d BK-4 first
version, 2a5ef8b rename of the RS-3 test, 7315215 BK-4 verify must report status ok, f67ebe8 docs/runbook.md Restore section,
1df779a BK-4 evidence rename. The commit of this handoff comes after them; see git log.
Pushed earlier, newest first: fbec6a2 RS-1, 7b364e1 BK-3, 9f230a5 BK-2 CronJob, c97506f pgserver sidecar, cb12c19 TLS generator,
8ffeaca ADR-0002, f10943d BK-1 verified, and older commits.

Deployed in the kind cluster, as last seen (2026-11-22, about 15:20 UTC):
- Namespace pg-ha: Patroni StatefulSet pg-ha, 3 pods with containers postgres, backup and pgserver, PostgreSQL 18.7, leader pg-ha-2,
  timeline 5; the object store objstore (Garage behind an nginx TLS front); CronJob pgbackrest-backup (0 2 * * *, Forbid) whose script
  (ConfigMap pgbackrest-cronjob-scripts, 45 lines) makes a full or incremental backup and then runs verify --output=text --verbose and
  fails the Job unless the exit code is 0 and the report has the line "status: ok"; ConfigMap pgbackrest-env with retention-full 2;
  Secrets pg-credentials, objstore-credentials, objstore-admin, objstore-tls, pgbackrest-tls-server, pgbackrest-tls-client.
- The live appdb holds the tables rs_sentinel, rs_pitr and rs_scratch, left on purpose.
- The repository holds 2 full backups (20261121-172516F, 20261122-041645F) and 5 incremental backups, status ok.
- Namespace pg-restore is RUNNING: a restored 3-pod Patroni cluster on timeline 6 (RS-2 data), with copies of pg-credentials and
  objstore-credentials. scripts/restore-down.sh deletes it (list and explicit go first).

Phase 3 items done, with evidence (docs/evidence/): 3 BK-1.txt; 4a and 4b BK-2.txt, BK-2-tls.txt, BK-2-pgserver.txt; 5 BK-3.txt;
6 BK-4.txt (stricter verify, 11 PASS) and BK-4-v2.txt (earlier run, 9 PASS); 7 RS-1.txt; 8 RS-2.txt; 9 RS-3.txt;
45 DOC-restore.txt. Supporting files: BK-2-tls-up, BK-2-pgserver-up, BK-2-pgserver-up2, BK-2-cronjob-up, BK-2-cron-fire, BK-3-config-up,
BK-4-config-up, BK-4-config-up2. Failed or red runs kept: BK-2-tls-FAILED, BK-2-pgserver-FAILED, BK-2-pgserver-run2-FAILED,
BK-2-FAILED, BK-3-FAILED, RS-1-FAILED, RS-2-FAILED, RS-3-FAILED, BK-4-FAILED, BK-4-run2-FAILED, BK-4-v3-FAILED, DOC-restore-FAILED.
Tests: tests/bk-tls.sh, bk-pgserver.sh, bk-schedule.sh, bk-retention.sh, bk-verify.sh, rs-full.sh, rs-pitr.sh, rs-restore-test.sh
(renamed from rs-scheduled.sh, ADR-0006 amendment 1), doc-restore.sh.
Decision records: ADR-0002 (amendments 1 and 2), ADR-0004, ADR-0005 (amendment 1), ADR-0006 (amendment 1).
docs/runbook.md holds only the Restore section. The OPS-3 runbooks are not written.

## b) Decisions
Tags, in the human's words: "REQUIRED = the brief states it; AREA = a graded area whose content I define; MINE = our own SPEC wording, not in the brief."

Made by the human, quoted:
- "SEC-2 (TLS for Postgres client and replication traffic) belongs to Phase 4."
- "Decision: Option A." (the access key id in Garage request logs), with these conditions:
  1. "Keep the failing OBJ-2 run as evidence under a -FAILED name, with a header line saying why it failed."
  2. "Record the test change in an ADR amendment: old check, new check, and why the access key ID is treated as an identifier. Say what you did not verify about Garage."
  3. "The three access-granting values stay scanned for in logs, repo files, ConfigMaps and evidence. The key ID stays scanned for in repo files and ConfigMaps."
  4. "Committed evidence must not contain the key ID. Print counts, not log lines that contain it."
  5. "Show me the exact before and after wording of the OBJ-2 sentence in SPEC.md before editing it."
  6. "Add a known-limitations entry stating that the access key ID appears in Garage's request logs, and nothing else."
- "SPEC.md line 51: use proposal B." Applied and committed in b4b75f2.
- "Item 1 is accepted: OBJ-2 is green (14 PASS, exit 0, header present, failed runs kept under -FAILED names)."
- "Decision for the running cluster: A, rebuild pg-ha from scratch." Executed; see BK-1-rebuild-*.txt in docs/evidence.
- "Yes, commit the BK-1 checkpoint locally, with the git add command and message you showed. Local only." Done as bca1654.
- "Hours log: I keep it myself in ~/hours-log.txt. Never ask me for it and never assume time."
- "Work through your numbered plan one item at a time: BK-1 first, then BK-2 to BK-4, then RS-1 to RS-3 (restore into an empty namespace, PITR, restore test), then monitoring and alerts, then security, then OPS (make up, make down, runbooks), then the documents. If you want a different order, ask me."
- "Start the monitoring and security items only when I say so. For each, give me options and costs first."
- "SPEC.md is mine: show the full current line and the full proposed line, and edit only after I approve."
- "At the end of every item, report in this format, nothing else: a) passed, with the evidence file name; b) failed or not verified; c) files to commit, by name, with the git add command and the commit message; d) what you propose next, and why."
- "The repo is public. Two identifiers must never appear in any file or evidence: my employer's name and the assignment's project name. The pre-commit hook blocks them. If the hook blocks a commit, tell me, never suggest --no-verify. Use "the assessment company" or "the project" in text."
- "Never paste the assignment text into any file. Describe requirements in your own words."
- Tags: "Item 1: REQUIRED, keep note [a]." "Item 14 (SEC-1): REQUIRED." "Item 11 (REP-4 Prometheus re-check): MINE." "Item 44 (AI process playbook): REQUIRED in substance; the file name is mine to choose." "Item 45 (documented restore procedure): REQUIRED." "Item 24 (design.md): REQUIRED, scope includes the four statements in point 1." "Items 41, 42, 26, 43: REQUIRED as you tagged." The four statements for design.md, in other words: the sync vs async choice and the RPO; the fencing and leader-election mechanism; the RTO that was measured and how; what changes on a real multi-zone cluster.
- "MINE (not in the brief): incrementals in BK-2, the word CronJob in BK-2, the word scheduled in RS-3, the exact alert list, the threat model file, and the seven handoff open items (34 to 40; the brief only forbids hiding known gaps, it does not require testing them)."
Added in the second phase 3 chat, in the human's words (typos kept):
- "one CronJob with `concurrencyPolicy: Forbid` for bk-2"; "keep 2" (retention-full).
- RS-1 shape: "B: a 3-pod Patroni cluster in `pg-restore`, bootstrapped from the repository." Names, the sentinel table with the extra
  full backup, the copied credentials and the delete and recreate of pg-restore in each test run were approved.
- "fixed scratch namespace so that we can test and i need we can delete it" (the restore namespace); "keep my list as it is".
- "go with b and not gap" (the temporary 2-minute CronJob test); "i oushed the code to gihub recently, its my own decison."
- RS-3 and BK-4 wording (the human ran the SPEC edit blocks): RS-3 is now "Restore test to a scratch instance, run on demand by one
  script, with a data check" and its test is tests/rs-restore-test.sh; the BK-4 entry names tests/bk-verify.sh and the Pass line
  "verify runs after each backup and its report says status ok, a verify error fails the Job, and the restore test of RS-3 passes".
  The BK-2 line stays "Scheduled full and incremental backups (CronJob)".
- "go with option 3" (BK-4: drop the two negative controls, ADR-0002 amendment 1); "F2: the script runs `verify --output=text
  --verbose`" (ADR-0002 amendment 2); "fix it" (the production script gap); "rename it" (the RS-3 test file); "approved" (the BK-4 Pass
  line); "move the v2 run to `BK-4-v2.txt` and the v3 run to `BK-4.txt`" (evidence names); "B: a "Restore" section in `docs/runbook.md`".
- RS-3 scheduling: the human's message "A: leave it unchanged. and change it to "Restore test to a scratch instance" named two options,
  and a later message was cut off after "instance". The assistant read it as the on-demand wording and the human ran the edit. The earlier
  wish "i want rs3 shecdhled in short time" was NOT built: no scheduled restore test exists. The human then answered "approve the text and
  an on-demand restore test acceptable" (2026-11-22), so on demand stands.
- Pending, marked pending: which phase holds OBS-1..3 and SEC-3..6 (only SEC-2 is assigned, to Phase 4); which MINE items get done; the
  optional second-agent run (item 46); the starts of monitoring, security, OPS and documents (options and costs first); whether the
  review chat is captured as a log.

## c) Remaining items, in order
Phase 3 items 3, 4a, 4b, 5, 6, 7, 8, 9 and 45 are done. When the human confirms, report that the phase is done so he can push.
- 10. OBS-1. 2.5. Needs 3. AREA.
- 11. REP-4 re-check: the Prometheus clause of REP-4 cannot hold before OBS-1. 0.5. Needs 10. MINE.
- 12. OBS-2. 2.0. Needs 10, 3, 4a. AREA.
- 13. OBS-3. 3.0. Needs 12 and 9. AREA.
- 14. SEC-1: gitleaks over git history (the hook scans staged changes only). 0.5. REQUIRED.
- 15. SEC-2. 3.0. AREA. The human assigned it to Phase 4.
- 16. SEC-3. 3.0. Needs 1 and 10. AREA.
- 17. SEC-4. 1.0. AREA.
- 18. SEC-5. 0.5. Needs 1. AREA.
- 19. SEC-6. 1.0. Needs the image pins. AREA.
- 20. OPS-1 make up and make test. 3.0. Needs everything deployable. REQUIRED.
- 21. OPS-1 clean-machine run. 1.0. Needs 20. REQUIRED.
- 22. OPS-2 make down. 0.5. Needs 20. REQUIRED.
- 23. OPS-3 runbooks (switchover, minor-version upgrade). 3.0. Needs 20. REQUIRED.
- 24. design.md. 2.0. Covers the four statements if ADR-0001, ADR-0003 and FO-1..3 already hold the RPO text, the fencing text and the RTO numbers and method (not read by the previous assistant); 2.5 if they do not. REQUIRED.
- 25. Threat model. 1.0. Needs 15 to 17. MINE.
- 26. Generalisation section (Redis Sentinel or Vault with Raft: files reused, files rewritten). 1.0. Needs 24. REQUIRED.
- 27. known-limitations.md consolidation. 0.5. REQUIRED.
- 41. Determinism section. 1.0. REQUIRED.
- 42. Agent-agnostic section. 1.0. Needs AGENTS.md. REQUIRED.
- 43. README with run instructions. 1.5. Needs 20 and 22. REQUIRED.
- 44. AI process playbook. 1.0. Needs 28, 41, 42. REQUIRED in substance.
- 28. Final AI-session log capture. 1.0. REQUIRED.
- 29. Headers for the 33 phase 2 evidence files. 0.5. MINE.
- 30. Final suite rerun and evidence refresh, including tests/ft-spread-pdb.sh, which was never rerun. 1.5. REQUIRED.
- 31. shellcheck, kubeconform, repo hygiene, commit prep. 1.0. MINE.
- 32. Video, 10 to 15 minutes (outline: 5 minutes each for approach, how to run, challenges; only things in the repo). 3.0. REQUIRED.
- 33. Submission email with repo link, video link and a rough hours count from the human's log. 0.5. REQUIRED.
- 34. fo-rejoin.sh log window 0.25. 35. Which pg_hba is effective 0.5. 36. Shorter wal_sender_timeout 0.75. 37. tcp_user_timeout on the primary 0.75.
  38. nftables variant of fo-split-brain.sh 1.0. 39. "WAL archive removes reinit" experiment 0.75 (needs BK-1). 40. WSL .wslconfig memory 0.25 (before OBS-1). All MINE.
- 46. Optional second-agent phase run, about 3.0. Not tagged.
Item 30 (final suite rerun) now also has to rerun tests/bk-schedule.sh, bk-retention.sh and rs-full.sh, because the CronJob script
gained the verify step after they last ran.

## d) Open risks and not verified (one line each)
- The BK-2 CronJob did not fire at 02:00 UTC (cause not found); it fired under a temporary 2-minute schedule (BK-2-cron-fire.txt).
  The real 02:00 firing is not shown, and from now on it runs the stricter verify.
- RS-3 is on demand only (accepted by the human); no scheduled restore test exists, so the OBS-2 alert "restore test failed" has no
  scheduled signal to rely on.
- Verify: pgBackRest 2.60.0 exits 0 when its report says status error. The script and tests/bk-verify.sh handle the missing-set case
  live; a damaged backup or archive file was not tested; two failure cases of the script ran only against a stand-in, output not saved.
- The suites that make Jobs from the CronJob template were not rerun after the verify change.
- The second rolling update moved the timeline from 2 to 5 (three promotions) with no write probe; overnight probe failures on pg-ha-2
  and pg-ha-0 had no restart and no promotion. Causes not found.
- Archiving after planned failovers showed no failures (twice). A crash-type failover, a replica catching up from the archive and the
  first-start failures on pg-ha-1 and pg-ha-2 are not examined.
- Not tested: Forbid blocking an overlap; which pod a backup reads from; the BK-2 Job 4 failure cause; time-based retention and
  differential backups; restore of an older backup, of an archive with a newer timeline, two restores at once, a target before the
  oldest kept full backup (not possible after retention).
- pg-restore holds the live passwords and the read-write store key and has the same Patroni system identifier as the live cluster.
  Only archive_mode=off and the timeline checks in the restore tests protect the live archive.
- pgBackRest server certificates last 825 days with no rotation; the CA key is removed with rm; authorisation by certificate name and
  stanza is not tested. No NetworkPolicy exists; SEC-3 must allow port 8432 and the pg-restore to object store path.
- History scans: gitleaks (34 commits, run before the last commits) clean; current secret values 0 files; the hook's pattern 0 matches
  in content, messages, authors, paths and refs. Not covered: secrets from before the BK-1 rebuild, binary files, GitHub objects
  served before the repository was recreated.
- The Phase 2 tests were not rerun on the rebuilt cluster (item 30). REP-4 lists a Prometheus clause that cannot be met before OBS-1.
- Object store: init repeatability, restart on its volume, hostname-mismatch rejection and a large transfer were shown in Docker only.
- The restore-test example in docs/runbook.md was not run in exactly that form.

## e) Rules in force
- The human decides what is cut or reduced; the assistant gives facts and options.
- Test first. A failing run is kept under a -FAILED name with an EXPECTED RED LINES header (scripts/apply-evidence-headers.sh).
- Never change a test without an ADR amendment saying what changed and why.
- Two failed attempts at the same step: stop and report.
- Mark every prediction as "prediction".
- Say what is not verified, in every report.
- No commit or push by the assistant. It gives the exact git add command by file name (never git add -A) with a count check, and a one-line commit message with no AI co-author or contributor trailer. The human commits locally and pushes only when a phase is done.
- Plain numbered steps; files created with tee and a heredoc; vim, not nano; no sudo for repo files.
- Never print or store a secret.
- The repo is public.

## f) AI session logs
Method: docs/ai-process/LOGGING.md (capture from the chat's share page, scripts/check-log.sh, scripts/redact-logs.sh which processes every
file in docs/ai-process/raw, commit docs/ai-process/redacted only). The human states that the logs are real and unedited apart from
secrets, and that the company and project names were also replaced (disclosed in LOGGING.md).
Captured: the phase 0 to 2 chat (docs/ai-process/redacted/2026-11-20-claude-chat-share-copy.txt).
Still to capture: a later copy of the phase 0 to 2 chat; the first phase 3 chat (markers file docs/ai-process/markers-phase3-chat.txt);
the second phase 3 chat that built BK-2 to BK-4, RS-1 to RS-3 and item 45 (markers file to create from a real capture); and the chat
after this handoff, at its end.
