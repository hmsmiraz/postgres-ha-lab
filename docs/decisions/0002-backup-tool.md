# ADR-0002: pgBackRest for backups, WAL archiving and PITR

Status: Accepted for the tool. Open for how scheduled backups reach the data (decided in Phase 3).

## Context
We need base backups, continuous WAL archiving to object storage, retention, verification and point-in-time recovery.

## Options
1. pgBackRest. Full, differential and incremental backups, retention settings, `verify`, PITR and S3 support in one tool.
2. WAL-G. Simpler to configure and fast, but retention and verification are less complete.
3. pg_basebackup plus a custom archive script. Most work, and we would own every edge case.

## Decision
pgBackRest. `archive_command` in the Postgres pods pushes WAL to the S3-compatible repository. Retention is declared in the pgBackRest configuration.

## Open question
How the scheduled backup job reaches the cluster: a CronJob using pgBackRest TLS server mode, or a sidecar. We decide this when we build Phase 3 and update this ADR.

## Consequences
- The image includes a pinned pgBackRest version.
- Backup, verify and restore scripts all use the same tool.
- Repository credentials are Kubernetes Secrets generated at `make up`.
