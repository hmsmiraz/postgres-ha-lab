# Handoff: end of phase 2, start of phase 3 (2026-11-21)

Read AGENTS.md, SPEC.md and docs/decisions/ first. Work test-first; keep failed runs as evidence.

## State of the system
- kind cluster "kind": 1 control-plane + 3 workers, zones zone-a/b/c (node labels), Calico v3.32.2.
- Image pg-ha:18.7-patroni4.1.5-pgbackrest2.60.0 (versions in versions.env), built by scripts/image-build.sh.
- Namespace pg-ha (restricted Pod Security), StatefulSet pg-ha (3 pods, anti-affinity + zone spread),
  services pg-primary / pg-replica / pg-ha-headless, PDB minAvailable 2, Patroni with Kubernetes ConfigMaps as DCS.
- Replication: physical streaming, slots, synchronous_mode on (non-strict, 1 sync standby),
  ttl 30 / loop_wait 10 / retry_timeout 10, max_slot_wal_keep_size 1GB, use_pg_rewind, wal_log_hints.
- Deploy: scripts/pg-up.sh (loads the image, generates secrets with scripts/gen-secrets.sh, applies k8s/pg/).

## Done, with evidence in docs/evidence/
REP-1..4, CON-1/2, FO-1..5, ADR-0001 degraded mode, REP-3 drill, FT-1/2, image build, cluster, redaction rules.
Failed or incomplete runs are kept next to the passing ones (names contain FAILED or INCOMPLETE).

## Not built yet
- pgBackRest is installed in the image but not configured: no archive_command, no repository, no backups.
- Object store (ADR-0004 is only "Proposed": MinIO if a pinned image can be pulled, else Garage).
- Restore, PITR, scheduled restore test (SPEC RS-1..3, BK-1..4). How scheduled backups reach the data is open (ADR-0002).
- Monitoring and alerts (OBS-1..3), TLS (SEC-2), NetworkPolicies for pg-ha (SEC-3), RBAC review (SEC-4), trivy scan (SEC-6).
- make up / make down, switchover and minor-upgrade runbooks, design.md, threat model, generalisation section,
  video, hours count for the submission email.

## Open items found during phase 2
- scripts/cluster-up.sh in the repo is the first version; the improved one (pull each image once on the host
  and kind-load it) was never applied. Apply and test it when building make up.
- tests/ft-spread-pdb.sh got a new line that prints the PDB message; it was not rerun. Rerun the suite at the end.
- tests/fo-rejoin.sh searches the whole pod log for "running pg_rewind"; it should be limited to the test window.
- tests/fo-split-brain.sh cuts traffic with iptables on the node (Calico can reorder its chains); an nftables table
  at priority -150 held in FO-5 and would be more robust. Optional.
- pg_hba rules exist both in the local Patroni file and in the DCS config; which one is effective was not tested.
- A lagging replica behind a silent partition needed "patronictl reinit" three times, because the WAL it needed was
  gone and there is no archive. Hypothesis to test in phase 3: a WAL archive removes this.
- With no synchronous standby and no primary, Patroni does not promote a replica (documented trade-off, ADR-0001
  amendment). wal_sender_timeout (1min) gave a 61 s commit stall; a shorter value was not tested.
- During a silent partition the primary's checkpoint waits on the lagging walsender; pg_wal grows by the volume
  written meanwhile (measured, docs/known-limitations.md). tcp_user_timeout on the primary is untested.
- WSL has 7.6 GiB RAM; monitoring may need more (.wslconfig) or a trimmed stack.

## Process rules in force
- Tests first, evidence saved under docs/evidence/, no claim without evidence, gaps go to docs/known-limitations.md.
- Commits are authored by the human only (no co-author trailers).
- Secrets are generated at deploy time and never printed or committed; the gitleaks pre-commit hook is active.
- AI session logs (docs/ai-process/LOGGING.md has the method): capture each chat at its end from the chat's share
  page, check it with scripts/check-log.sh, redact with scripts/redact-logs.sh (rules in scripts/redact.pl, tested by
  tests/redact-test.sh), commit docs/ai-process/redacted only. Raw logs stay out of git.
- The phase 0-2 chat log ends before the redaction rework; a later copy of that chat should cover its tail.
