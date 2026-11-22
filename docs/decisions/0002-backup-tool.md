# ADR-0002: pgBackRest for backups, WAL archiving and PITR

Status: Accepted. Scheduled backups run as CronJobs that reach the Postgres pods through pgBackRest TLS server mode (decided in Phase 3).

## Context
We need base backups, continuous WAL archiving to object storage, retention, verification and point-in-time recovery.

## Options
1. pgBackRest. Full, differential and incremental backups, retention settings, `verify`, PITR and S3 support in one tool.
2. WAL-G. Simpler to configure and fast, but retention and verification are less complete.
3. pg_basebackup plus a custom archive script. Most work, and we would own every edge case.

## Decision
pgBackRest. `archive_command` in the Postgres pods pushes WAL to the S3-compatible repository. Retention is declared in the pgBackRest configuration.

## Decision on the backup trigger
CronJobs run pgBackRest from the same pinned image and reach the Postgres pods through pgBackRest TLS server mode, with a `pgserver` sidecar in each pod and certificates generated at `make up`. Options not chosen: a scheduler in a sidecar (backup load in the leader pod, weak failure visibility) and a CronJob using kubectl exec (broad pods/exec permission, conflicts with least privilege). Shown by tests/bk-pgserver.sh: pgbackrest check works through three TLS pg hosts. Not verified: which pod a backup reads from, overlapping backups (only Forbid is checked), certificate rotation.

## Consequences
- The image includes a pinned pgBackRest version.
- Backup, verify and restore scripts all use the same tool.
- Repository credentials are Kubernetes Secrets generated at `make up`.
- A new port (8432) and a certificate set exist; both must be covered by the NetworkPolicies of SEC-3.

## Amendment 1 (BK-4 test, 2026-11-22)
Old check: the first version of tests/bk-verify.sh (its failed run is docs/evidence/BK-4-run2-FAILED.txt) had two negative
controls after the positive path: (A) pgbackrest verify of a backup set that does not exist must exit non-zero, (B) a Job with
that set in VERIFY_SET must fail and log "verify FAILED".
New check: both controls are removed. The test keeps the positive path: the backup script runs verify, Job 1 adds one
incremental backup and logs "verify ok", and a direct verify in a pg pod exits 0.
Why: pgBackRest 2.60.0 verify exits 0 and prints "status: error" and "backup set ... is not valid" for a set that does not
exist ("verify command end: completed successfully"). The controls assumed a non-zero exit and could not pass. Of the
alternatives (judge the output text, use an invalid option, damage a copy of a repository) the human chose to drop the controls.
Not verified: that a failing verify fails the Job. The script checks only the exit code, and verify returned 0 for the one error
case tried. Whether verify exits non-zero for a damaged backup or archive file was not tested. The failure paths of the script
were run only against a stand-in for pgbackrest, and that output is not saved in the repository.

## Amendment 2 (BK-4 script and test, 2026-11-22)
Old check: after Amendment 1 the backup script ran "pgbackrest verify" with the default output (none) and failed the Job only on a
non-zero exit; tests/bk-verify.sh showed the positive path only (docs/evidence/BK-4.txt).
New check: the script runs "pgbackrest verify --output=text --verbose", prints the report, and fails the Job unless the exit code
is 0 and the report has the line "status: ok" (option F2, chosen by the human). tests/bk-verify.sh also checks the live script
text, that a direct verify of a missing backup set prints "status: error", and that a Job with that set (VERIFY_SET) fails, logs
"verify FAILED" and still adds one incremental backup.
Why: pgBackRest 2.60.0 verify exits 0 when it reports "status: error" (observed for a missing backup set) and prints nothing unless
--output=text is given, so the old script could not fail on a reported error.
Not verified: that verify reports "status: error" for a damaged backup or archive file (only the missing-set error is produced
here); that another pgBackRest version keeps the wording "status: ok" (a different wording would fail the Job, the safe direction).
