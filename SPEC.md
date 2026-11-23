# SPEC: PostgreSQL HA on Kubernetes (no operator)

Stack: Patroni (Kubernetes API as DCS), pgBackRest, S3-compatible object store, kind + Calico.
Every requirement has a test in `tests/` and an evidence file in `docs/evidence/`.
Targets below are goals. Measured values go in the evidence files.

## REP: Replication
- REP-1: 1 primary + 2 replicas, PostgreSQL >= 15, physical streaming replication.
  Test: `tests/rep-topology.sh`. Pass: `patronictl list` shows 1 Leader + 2 streaming replicas.
  Evidence: `docs/evidence/REP-1.txt`
- REP-2: Synchronous replication with one sync standby. ADR-0001 states the RPO and the degraded case.
  Test: `tests/rep-sync.sh`. Pass: `pg_stat_replication` shows one `sync` row and a write is acknowledged only after the standby confirms.
  Evidence: `docs/evidence/REP-2.txt`
- REP-3: Replication slots with disk protection (`max_slot_wal_keep_size`).
  Test: `tests/rep-slots.sh`. Pass: slots exist for both replicas, and a stopped replica cannot grow WAL past the limit.
  Evidence: `docs/evidence/REP-3.txt`
- REP-4: Replication lag is measured.
  Test: `tests/rep-lag.sh` (lag in bytes and time from SQL) and `tests/obs-rep-lag.sh` (lag in bytes and seconds in Prometheus). Pass: lag in bytes and seconds is queried, and appears as a Prometheus metric that rises above 0 while WAL replay on the async replica is paused and returns to 0 after it resumes.
  Evidence: `docs/evidence/REP-4.txt` and `docs/evidence/REP-4-prometheus.txt`

## CON: Connectivity
- CON-1: Stable read-write service always routes to the current primary.
  Test: `tests/con-rw.sh`. Pass: `pg_is_in_recovery()` is false through the rw service, before and after failover.
  Evidence: `docs/evidence/CON-1.txt`
- CON-2: Separate read-only service routes to replicas only.
  Test: `tests/con-ro.sh`. Pass: `pg_is_in_recovery()` is true through the ro service, and writes are rejected.
  Evidence: `docs/evidence/CON-2.txt`
- CON-3: Clients reconnect after failover with no manual change.
  Test: the write probe in `tests/fo-*.sh`. Pass: probe resumes writing through the same endpoint.
  Evidence: `docs/evidence/CON-3.txt`

## FO: Failover
- FO-1: Primary pod killed, replica promoted automatically. Target RTO <= 60 s.
  Test: `tests/fo-pod-kill.sh`. Evidence: `docs/evidence/FO-1.txt` with the measured RTO.
- FO-2: Primary node lost (`docker stop` of the kind node). Target RTO <= 90 s.
  Test: `tests/fo-node-stop.sh`. Evidence: `docs/evidence/FO-2.txt`
- FO-3: Primary storage lost (PVC deleted). Replica promoted, the new pod re-clones.
  Test: `tests/fo-pvc-loss.sh`. Evidence: `docs/evidence/FO-3.txt`
- FO-4: No split-brain. A primary cut off from the Kubernetes API demotes itself, and two writable primaries never exist.
  Test: `tests/fo-split-brain.sh`. Pass: at no sampled moment do two pods report `pg_is_in_recovery() = false`.
  Evidence: `docs/evidence/FO-4.txt`
- FO-5: The old primary rejoins as a replica automatically (pg_rewind, re-clone as fallback).
  Test: `tests/fo-rejoin.sh`. Evidence: `docs/evidence/FO-5.txt`
- FO-6: RTO method: a probe inserts a timestamped row every 100 ms, and RTO is the largest gap between successful writes.
  Evidence: the FO-1 to FO-3 files.

## OBJ: Object store
- OBJ-1: The object store image and its TLS proxy image are pinned by tag and digest and pull anonymously. ADR-0004, ADR-0005.
  Test: `tests/obj-image.sh`. Evidence: `docs/evidence/OBJ-1.txt`
- OBJ-2: The object store runs in the cluster behind TLS. Garage S3, admin and RPC ports listen on loopback only, and the TLS front exposes only S3 (3900) and admin (3903). Bucket, key and permissions are created by an idempotent Job, not by hand.
  Test: `tests/obj-s3.sh`. Pass: pgBackRest write, list, read and delete succeed over TLS with certificate verification on and fail without the CA; plaintext ports are closed on the pod IP; the cluster holds no CA private key (the Secret objstore-tls holds exactly ca.crt, tls.crt and tls.key); the three access-granting secret values (secret access key, admin token, RPC secret) appear in no repo file (working tree, not git history), evidence file, ConfigMap or pod log; the access key ID, an identifier that Garage writes to its request logs, appears in no repo file (working tree, not git history), evidence file or ConfigMap.
  Evidence: `docs/evidence/OBJ-2.txt`

## BK: Backups
- BK-1: Continuous WAL archiving to object storage.
  Test: `tests/bk-wal.sh`. Pass: `pgbackrest check` succeeds and new WAL objects appear.
  Evidence: `docs/evidence/BK-1.txt`
- BK-2: Scheduled full and incremental backups (CronJob).
  Test: `tests/bk-schedule.sh`. Evidence: `docs/evidence/BK-2.txt`
- BK-3: Retention enforced by pgBackRest settings.
  Test: `tests/bk-retention.sh`. Pass: backups beyond the limit are expired.
  Evidence: `docs/evidence/BK-3.txt`
- BK-4: Backups verified automatically (`pgbackrest verify` after each backup in the backup CronJob, plus the restore test in RS-3).
  Test: `tests/bk-verify.sh`. Pass: verify runs after each backup and its report says status ok, a verify error fails the Job, and the restore test of RS-3 passes.
  Evidence: `docs/evidence/BK-4.txt`

## RS: Restore
- RS-1: Full cluster restore into an empty namespace by one script.
  Test: `tests/rs-full.sh`. Pass: restored data matches the sentinel dataset.
  Evidence: `docs/evidence/RS-1.txt`
- RS-2: Point-in-time recovery to a timestamp.
  Test: `tests/rs-pitr.sh`. Pass: rows written before the target time exist, rows written after do not.
  Evidence: `docs/evidence/RS-2.txt`
- RS-3: Restore test to a scratch instance, run on demand by one script, with a data check.
  Test: `tests/rs-restore-test.sh`. Evidence: `docs/evidence/RS-3.txt`

## OPS: Operability
- OPS-1: `make up` brings up everything. Test: from a clean machine, `make up && make test` passes.
- OPS-2: `make down` removes everything. Pass: no kind cluster and no leftover volumes.
- OPS-3: Runbooks for planned switchover and minor-version upgrade in `docs/runbook.md`.

## SEC: Security
- SEC-1: Secrets generated at `make up`, none committed. Test: gitleaks on the repo and history.
- SEC-2: `scram-sha-256` and TLS for client and replication traffic.
- SEC-3: Default-deny NetworkPolicies with explicit allows. Test: a blocked connection is demonstrated.
- SEC-4: Least-privilege RBAC for Patroni.
- SEC-5: Non-root containers, dropped capabilities, restricted Pod Security Standard.
- SEC-6: Image scan with trivy. Evidence: `docs/evidence/SEC-6.txt`

## OBS: Observability
- OBS-1: Prometheus scrapes postgres_exporter and Patroni metrics.
- OBS-2: Alerts: no primary, replication lag, slot retention, WAL archive failure, backup too old, restore test failed.
- OBS-3: Each alert is triggered once on purpose, and the firing is saved as evidence.

## FT: Fault tolerance
- FT-1: Pod anti-affinity and topology spread across nodes and fake zones.
- FT-2: PodDisruptionBudget, resource requests and limits, probes, and a termination grace period.

## DOC: Documentation
- DOC-1: `docs/design.md`, `docs/runbook.md`, `docs/known-limitations.md`, ADRs, and the AI-process docs.
