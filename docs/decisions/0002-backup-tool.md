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
CronJobs run pgBackRest from the same pinned image and reach the Postgres pods through pgBackRest TLS server mode, with a `pgserver` sidecar in each pod and certificates generated at `make up`. Options not chosen: a scheduler in a sidecar (backup load in the leader pod, weak failure visibility) and a CronJob using kubectl exec (broad pods/exec permission, conflicts with least privilege). Not verified yet: leader selection with three pg hosts, overlapping backups, certificate rotation.

## Consequences
- The image includes a pinned pgBackRest version.
- Backup, verify and restore scripts all use the same tool.
- Repository credentials are Kubernetes Secrets generated at `make up`.
- A new port (8432) and a certificate set exist; both must be covered by the NetworkPolicies of SEC-3.
