# Handoff: Phase 3 in progress (updated 2026-11-21; Phase 3 is NOT done)

Read AGENTS.md, SPEC.md and docs/decisions/ first. Work test-first; keep failed runs as evidence.
A new chat has only the repo files it is given and the human's opening message. "Estimate" means an estimate by the previous
assistant, in hours, not measured. "Prediction" means not verified.

## a) Current state
Commits on main, newest first. Nothing is pushed.
- bca1654 feat: BK-1 WAL archiving configuration and backup sidecar (static checks only, not yet verified in the cluster)
- b4b75f2 feat: in-cluster Garage object store behind an nginx TLS front (OBJ-1, OBJ-2, ADR-0004, ADR-0005)
- c13d9bf chore: pre-commit hook blocks forbidden identifiers; test
(This handoff update is committed after these; see git log.)

Deployed in the kind cluster, as last seen by the assistant (not looked at since):
  UPDATE: the bullets below describe the cluster before the rebuild. The rebuild is done (docs/evidence/BK-1-rebuild-*.txt): pg-ha was recreated from the BK-1 template with the backup sidecar, and the BK-1 files are applied.
- Namespace pg-ha holds the Patroni StatefulSet pg-ha (3 pods, ONE container "postgres": the pod template from before BK-1, with
  no archive_mode and no backup sidecar), the object store StatefulSet objstore (pod objstore-0, containers garage and tls, 2/2
  Running), the completed Job objstore-init, and the Secrets pg-credentials, objstore-credentials, objstore-admin, objstore-tls.
- The BK-1 files in the repo (k8s/pg/25-pgbackrest.yaml, k8s/pg/20-config.yaml, k8s/pg/50-statefulset.yaml, scripts/pg-up.sh) are
  committed but NOT applied to the cluster.

Passed, with evidence (docs/evidence/):
- OBJ-1: OBJ-1.txt (both object store images pinned by digest and pulled anonymously).
- OBJ-2 secrets generator: OBJ-2-secrets.txt.
- OBJ-2 manifests, static: OBJ-2-manifests-static.txt.
- OBJ-2 deploy: OBJ-2-up.txt.
- OBJ-2 in the cluster: OBJ-2.txt (14 PASS, exit 0; leak rules as in ADR-0005 amendment 1).
- BK-1: verified in the cluster after the rebuild: docs/evidence/BK-1.txt (13 PASS, exit 0). Earlier red runs kept: BK-1-FAILED.txt and BK-1-FAILED-v2.txt (archive_mode off, deliberate). Static evidence: BK-1-static.txt.
Failed or invalid runs kept next to the passing ones: OBJ-1-FAILED-v1, OBJ-1-FAILED-v2, OBJ-2-FAILED-v1, OBJ-2-FAILED-v2, OBJ-2-FAILED-v3,
OBJ-2-secrets-FAILED, OBJ-2-leak-FAILED, OBJ-2-run2-FAILED, OBJ-2-manifests-static-run1, OBJ-2-before-leak-fix, OBJ-static-checks-run1,
OBJ-static-checks-run2, ADR-0004-image-pin-FAILED, ADR-0005-verify-spike-run1. Each has an EXPECTED RED LINES header
(scripts/apply-evidence-headers.sh).
Phase 0 to 2 results (REP-1..4, CON-1/2, FO-1..5, FT-1/2, ADR-0001 and the drills) are listed in handoff-phase2-to-phase3.md. They were
not rerun in this phase, and 33 of those evidence files have no EXPECTED RED LINES header.
Decision records: ADR-0004 Accepted. ADR-0005 Accepted, with Amendment 1 (the access key id appears in Garage request logs).
ADR-0002 is still open on the backup trigger.

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

SPEC.md wording:
- Approved and applied: the OBJ-2 test sentence, proposal B (above). The OBJ section (OBJ-1 and OBJ-2) was added by commands the human ran.
- NOT approved, and no edit was proposed with the full current and proposed lines: the BK-2 wording ("CronJob", and "full and incremental") and the RS-3 wording ("Scheduled restore test"). The human has said an on-demand restore test is fine; that is not an approval of any SPEC edit.

Pending, marked pending:
- PENDING: the backup trigger (ADR-0002). Options so far: a scheduler sidecar in the Postgres pods (the assistant's proposal, NOT approved); a CronJob with pgBackRest TLS server mode; a CronJob that runs kubectl exec.
- PENDING: whether the restore test is on-demand or scheduled (the plan assumed on-demand, which the human has not confirmed).
- PENDING: which phase holds OBS-1..3 and SEC-3..6 (only SEC-2 is assigned, to Phase 4).
- PENDING: which MINE items get done: 4b, 9b, 11, 25, 29, 31, and the seven open items 34 to 40.
- PENDING: the optional second-agent phase run (item 46).
- PENDING: whether the review chat is captured as a log.

## c) Remaining items, in order (item numbers are from the previous chat's plan; hours are estimates, not measured)
Plan total 63.0 h (REQUIRED 39.0, AREA 16.0, MINE 8.0), of which 3.0 h is items 1, 2a, 2b (done). Items 9b and 46 are not in the total.
- 3. BK-1 WAL archiving. 3.0 total; implementation and static checks are done and the item was not re-estimated. Needs the object store (done). REQUIRED.
- 4a. BK-2 scheduled full backups. 2.0. Needs 3 and the ADR-0002 decision. REQUIRED.
- 4b. BK-2 incrementals. 0.5. Needs 4a. MINE.
- 5. BK-3 retention. 1.0. Needs 4a. pgBackRest already warned that repo1-retention-full is not set (docs/evidence/ADR-0005-verify-spike.txt). REQUIRED.
- 6. BK-4 verify. 1.0. Needs 4a and 9. REQUIRED.
- 7. RS-1 restore into an empty namespace. 4.0. Needs 3 and 4a. REQUIRED.
- 8. RS-2 PITR. 1.5. Needs 7. REQUIRED.
- 9. RS-3 on-demand restore test. 1.0. Needs 7. REQUIRED. (9b, the scheduled version, +1.0, MINE.)
- 45. Documented restore procedure. 0.75. Needs 7 and 8. REQUIRED.
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

First next step: option A, rebuild pg-ha from scratch (the human decided). The new chat must show these steps to the human and wait for a go.
R0. Read-only pre-checks, saved as evidence:
```bash
{
  echo "date_utc: $(date -u +%FT%TZ)"
  git status --short | cat
  git log --oneline -3 | cat
  echo "--- nodes and namespaces"
  kubectl get nodes --no-headers | cat
  kubectl get ns --no-headers | cat
  echo "--- everything in pg-ha (R2 deletes all of it; Secret names only, no values)"
  kubectl -n pg-ha get sts,job,svc,pdb,cm,secret,pvc --no-headers | cat
  echo "--- volumes bound to claims (reclaim policy Delete: removed with their claims)"
  kubectl get pv -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name,RECLAIM:.spec.persistentVolumeReclaimPolicy,SIZE:.spec.capacity.storage | cat
  echo "--- user databases and tables that R2 destroys (names only)"
  kubectl -n pg-ha exec pg-ha-0 -c postgres -- psql -U postgres -At -c "select datname from pg_database where not datistemplate" | cat
  kubectl -n pg-ha exec pg-ha-0 -c postgres -- psql -U postgres -d appdb -At -c "select schemaname || '.' || relname from pg_stat_user_tables" 2>&1 | cat
  echo "--- the new pod template under restricted admission (server-side dry run, nothing is created)"
  . ./versions.env
  r=$(mktemp -d)
  sed "s|__IMAGE__|${IMAGE_NAME}:${IMAGE_TAG}|g" k8s/pg/50-statefulset.yaml >"$r/sts.yaml"
  kubectl create --dry-run=client -f "$r/sts.yaml" -o json >"$r/sts.json"
  jq '{apiVersion:"v1",kind:"Pod",metadata:{name:"pg-ha-psa-check",namespace:"pg-ha",labels:.spec.template.metadata.labels},spec:(.spec.template.spec | .volumes += [{"name":"data","emptyDir":{}}])}' "$r/sts.json" >"$r/pod.json"
  kubectl apply --dry-run=server -f "$r/pod.json" 2>&1 | cat
  rm -rf "$r"
  echo "--- scripts and image"
  shellcheck scripts/pg-up.sh scripts/objstore-up.sh scripts/gen-objstore-secrets.sh && echo "shellcheck clean"
  docker image inspect "${IMAGE_NAME}:${IMAGE_TAG}" --format 'pg-ha image present {{.Id}}' | cut -c1-40
} 2>&1 | tee docs/evidence/BK-1-rebuild-precheck.txt
```
R1. The human reads the output. Stop if the admission dry run is rejected or shellcheck complains.
R2. Delete: kubectl delete namespace pg-ha --wait=true --timeout=300s
    This deletes everything in the namespace: both StatefulSets and their pods, the 4 claims (3 Postgres, 1 Garage) and their volumes, the Secrets
    (pg-credentials, objstore-credentials, objstore-admin, objstore-tls), the ConfigMaps (including Patroni's DCS ConfigMaps), Services, PDB, the Job, and the
    patroni ServiceAccount, Role and RoleBinding. It does not touch the kind cluster, the nodes, Calico, local-path-storage, the images cached on the nodes,
    the repo or the evidence files.
R3. Verify, read-only: kubectl get ns pg-ha 2>&1 | tail -n 1 (expect NotFound); kubectl get pv --no-headers | cat (no pg-ha claims left);
    kubectl -n local-path-storage get pods --no-headers | cat
R4. scripts/objstore-up.sh 2>&1 | tee docs/evidence/BK-1-rebuild-objstore-up.txt
R6. timeout 900 scripts/pg-up.sh 2>&1 | tee docs/evidence/BK-1-rebuild-pg-up.txt   (runs before R5: tests/obj-s3.sh line 35 needs the StatefulSet pg-ha to exist)
R5. tests/obj-s3.sh 2>&1 | tee docs/evidence/BK-1-rebuild-obj-s3.txt   (runs after R6; stop if red)
    Run before R6, R5 failed at line 35 (docs/evidence/BK-1-rebuild-obj-s3-FAILED.txt). The order is R4, R6, R5, R7, R8.
R7. tests/rep-topology.sh 2>&1 | tee docs/evidence/BK-1-rebuild-rep-topology.txt
R8. tests/bk-wal.sh 2>&1 | tee docs/evidence/BK-1.txt
    If it fails, rename docs/evidence/BK-1.txt to BK-1-run1-FAILED.txt before any rerun, and report.
Then: add EXPECTED RED LINES headers for the new evidence files in scripts/apply-evidence-headers.sh, write the two known-limitations entries (see d), and give
the human the git add command and commit message. After the rebuild, the phase 2 failover tests have to be rerun later (item 30).

## d) Open risks and not verified (one line each)
- BK-1 is verified in the cluster (BK-1.txt). Not verified: archiving after a failover; the first-start archive failures were looked at on pg-ha-0 only.
- Whether bootstrap.dcs (with archive_mode and archive_command) applies only at first initialisation: assumed from Patroni's design, not tested; this is why the rebuild is needed.
- archive-push over TLS from the postgres container under its 768 Mi memory limit: not tested.
- The sidecar mounts the data volume read-only; whether pgBackRest needs to write there: not tested.
- psql over the socket from the sidecar (peer authentication as postgres): prediction, not tested.
- A stanza created by one leader being found by the next leader after a failover: not tested.
- The sidecar checks every 60 s, so the first stanza can take up to that long to appear; the test waits 180 s: prediction.
- The new StatefulSet template under restricted admission: only checked by the R0 dry run of a bare Pod, which is a proxy.
- Four phase 2 tests call kubectl logs "$PROBE" on a probe pod (fo-node-stop, fo-pod-kill, fo-pvc-loss, fo-split-brain): candidates only, not read.
- Object store: init repeatability, restart on its volume, hostname-mismatch rejection and a large transfer are shown in Docker only, not in the cluster (see known-limitations).
- Git history has not been scanned for secrets (SEC-1).
- REP-4 lists a Prometheus clause that cannot be met before OBS-1.
Known-limitations entries written after BK-1 (docs/known-limitations.md, Backup and recovery):
- Archiving fails while the object store is down, so pg_wal grows on the 2 GiB volume. Not tested.
- archive_timeout is unset, so a quiet cluster can leave its latest WAL segment unarchived. Not tested.
The old entry "No WAL archive or base backups exist yet" was reworded after BK-1 passed: WAL archiving works, no base backup exists yet.

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
Method: docs/ai-process/LOGGING.md (not re-read by the previous assistant). From the phase 2 handoff: capture each chat at its end from the chat's share page, check it with
scripts/check-log.sh, redact with scripts/redact-logs.sh (rules in scripts/redact.pl, tested by tests/redact-test.sh), commit docs/ai-process/redacted only. Raw logs stay out of
git (docs/ai-process/raw/ is in .gitignore). The human states that the logs are real and unedited apart from secrets, and that the company and project names were also replaced,
disclosed in LOGGING.md.
Still to capture:
- The phase 0 to 2 chat: a later copy covering its tail (per the phase 2 handoff).
- The phase 3 chat that wrote this note: not captured yet. A marker file with ten of its headings is docs/ai-process/markers-phase3-chat.txt (committed).
  scripts/check-log.sh now takes an optional second argument, a markers file (default: its built-in list for the phase 0 to 2 chat). Evidence: LOG-check-markers.txt (red run: LOG-check-markers-FAILED.txt). Use: scripts/check-log.sh <log> docs/ai-process/markers-phase3-chat.txt
- This chat itself, at its end.
