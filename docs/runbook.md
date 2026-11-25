# Runbook

This file holds the operating procedures written so far. Only the Restore section exists. The runbooks for a planned switchover and
a minor-version upgrade (OPS-3) are not written.

## Restore

This section covers restoring the live PostgreSQL cluster (namespace pg-ha, pgBackRest stanza pg-ha) into the fixed scratch
namespace pg-restore. Moving applications over to a restored cluster was not built or tested. What was tested is shown by the
evidence files named below, and what was not tested is listed in docs/known-limitations.md.
The design and its reasons are in docs/decisions/0006-restore-design.md.

### What a restore reads

- The repository is the in-cluster object store behind TLS. A restore takes the latest backup plus the archived WAL.
- WAL that is not archived yet is not in a restore. To include the newest writes, run `select pg_switch_wal()` on the leader and
  wait until pg_stat_archiver shows that segment as archived. archive_timeout is 0, so a quiet cluster does not archive on its own.
- Retention is retention-full=2 (type count). Only the 2 newest full backups and their incrementals are kept, and WAL older than
  the start of the oldest kept full backup is expired. A target time before that backup cannot be restored.
- To see the backups, run: `kubectl -n pg-ha exec pg-ha-2 -c postgres -- pgbackrest --stanza=pg-ha info`

### Full restore (RS-1)

1. Run `scripts/restore-full.sh` from the repository root. It stops if the namespace pg-restore already exists. Remove it first
   with scripts/restore-down.sh.
2. It creates pg-restore, copies the Secrets pg-credentials and objstore-credentials from pg-ha without printing them, creates the
   Secret objstore-ca from ca.crt only, applies the manifests in k8s/restore/ and waits up to 900 seconds.
3. A 3-pod Patroni cluster (pg-restore-0 to pg-restore-2) bootstraps with pgbackrest restore from the live repository, with
   archive_mode off. It ends with 1 leader and 2 streaming replicas.
4. Check the result with: `kubectl -n pg-restore exec pg-restore-0 -c postgres -- patronictl -c /etc/patroni/patroni.yml list`
5. The test is tests/rs-full.sh and its evidence is docs/evidence/RS-1.txt.

### Point-in-time recovery (RS-2)

Set RESTORE_TARGET to a UTC timestamp in the format the RS-2 test used:
`RESTORE_TARGET='2026-11-22 05:21:26.984816+00' scripts/restore-full.sh`
RESTORE_TYPE defaults to time and RESTORE_TARGET_ACTION defaults to promote. The script writes them into the ConfigMap
pgbackrest-env in pg-restore before the pods start. Keep the action at promote. The pgBackRest default is pause, which was not tried.
The test is tests/rs-pitr.sh and its evidence is docs/evidence/RS-2.txt. For a time target pgBackRest chooses the backup, and which
one it chose was not checked.

### Scratch restore test (RS-3)

`scripts/restore-test.sh` restores the latest backup plus the archived WAL into one plain Postgres pod, pg-restore-test, in
pg-restore (emptyDir data, no Patroni, archive_mode off). It runs a query and compares the result with a value you give it.

- RESTORE_TEST_SQL is a query that returns one value. RESTORE_TEST_EXPECT is the expected value.
- RESTORE_TEST_KEEP=1 keeps the pod after the run. RESTORE_TEST_TIMEOUT is the wait in seconds (default 600).
- The script exits non-zero if the result differs from the expected value. It removes the pod unless RESTORE_TEST_KEEP is 1.
- It prints row counts, not data. It never deletes a namespace and accepts only pg-restore.
- The pod does not read the ConfigMap pgbackrest-env, so a point-in-time target left there by RS-2 does not change this test.

An example with the table rs_scratch, which the test leaves in the live database (not run in exactly this form):
`RESTORE_TEST_SQL='select count(*) from rs_scratch' RESTORE_TEST_EXPECT=300 scripts/restore-test.sh`
The test is tests/rs-restore-test.sh and its evidence is docs/evidence/RS-3.txt, made before the test file was renamed
(ADR-0006 amendment 1).

### Removing the scratch namespace

`scripts/restore-down.sh` lists what pg-restore holds and then deletes the namespace: the pods, the PVCs, the copied Secrets, the
ConfigMaps, the Services and the Role. It refuses any other namespace and deletes nothing in pg-ha. Until it runs, pg-restore
holds copies of the live database passwords and the read-write object store key.

### What protects the live archive

- The restored cluster runs with archive_mode off (the Patroni config in k8s/restore/20-config.yaml and the restore option
  archive-mode=off), so it does not push WAL into the live repository.
- The restore tests check this. The restored instance is on a newer timeline than the newest one in the live archive, and the
  newest timeline in the live archive is unchanged afterwards (docs/evidence/RS-1.txt, docs/evidence/RS-2.txt and
  docs/evidence/RS-3.txt).
- The restored cluster has the same Patroni system identifier as the live one. Only archive_mode off keeps its WAL out of the
  live archive, so do not turn archiving on in pg-restore.

### Not tested

- Restoring an older backup. The scripts take no backup set.
- A target before the oldest kept full backup (not possible after retention), a target inside a failover, exclusive targets, and
  recovery types other than time.
- A restore when the archive lacks WAL, two restores at the same time, and production-sized data. The database was about 30 MB and
  the restore pods have a memory limit of 768Mi.
- Moving applications to a restored cluster, and the NetworkPolicies this would need (none exist).
- The full list is in docs/known-limitations.md.

## Planned switchover

Moves the leader role to the synchronous standby on purpose. Tested live on 24 Nov 2026 (docs/evidence/OPS-3-switchover.txt).

### Preconditions

- Patroni shows 1 leader and 2 streaming members: `kubectl -n pg-ha exec pg-ha-0 -c postgres -- patronictl -c /etc/patroni/patroni.yml list`
- No backup Job is running (`kubectl -n pg-ha get jobs`) and it is not close to 02:00 UTC, when the backup CronJob starts.

### Steps

1. Start the write probe from tests/lib/probe.sh (function start_probe). It inserts a row every 100 ms through pg-primary.
2. Note the leader and the Sync Standby in the patronictl list output.
3. Run: `kubectl -n pg-ha exec <leader> -c postgres -- patronictl -c /etc/patroni/patroni.yml switchover --leader <leader> --candidate <sync standby> --force`
4. Wait until patronictl list shows 1 leader and 2 streaming members again.
5. The script tests/ops-switchover.sh does all of this and prints the results.

### Checks afterwards

- The candidate is the new leader and the timeline rose by 1.
- No acknowledged probe write is missing, and exactly one pod is writable.
- tests/sec-tls.sh shows 12 PASS (TLS still enforced) and tests/obs-exporter-live.sh shows 12 PASS.

### Rollback

Run the same switchover command again with the old leader as the candidate. The rollback was not tested.

### Measured on 24 Nov 2026

Leader pg-ha-2 to pg-ha-1, timeline 12 to 13, 87 writes acknowledged and 0 missing, largest gap between writes 16047 ms, 12 failed attempts, one run. Not tested: switchover under heavy load, during a backup, and the rollback.

## Minor-version upgrade

A three-member rehearsal upgraded PostgreSQL 18.6 to 18.7 using the rollout below in a separate namespace with its own data volumes and object store. All members reported 180006 before and 180007 afterward. The probe found zero missing acknowledged writes. [Rehearsal output](evidence/gap-verification/minor-upgrade.txt)

### Steps

1. Pick the target tag from Docker Hub (postgres, trixie variant). Probe it first: anonymous pull, digest.
2. Edit versions.env: POSTGRES_VERSION, POSTGRES_BASE_IMAGE (tag and digest), IMAGE_TAG, and PGBACKREST_APT_VERSION if the PGDG repo of the new base carries another pgBackRest build. Update the pin tests first (test first).
3. Build: `bash scripts/image-build.sh`
4. Load into every node by name:tag: `kind load docker-image pg-ha:<IMAGE_TAG> --name kind`
5. Start the write probe (tests/lib/probe.sh, function start_probe).
6. Apply: `bash scripts/pg-up.sh`, then `kubectl -n pg-ha rollout status sts/pg-ha --timeout=900s`. The StatefulSet restarts pods in ordinal order. Which member holds the leader lock can change during the rollout.
7. Check: 1 leader and 2 streaming members, `select version()` on each pod, no acknowledged write missing, tests/sec-tls.sh and tests/obs-exporter-live.sh at 12 PASS.

### Rollback

Restore the old pins in versions.env and apply again as in steps 4 to 6, or run `kubectl -n pg-ha rollout undo sts/pg-ha`. Neither was tested for an upgrade.

### Not tested

The rehearsal covered the forward 18.6-to-18.7 rollout. Rollback and later minor releases remain untested. The new base must have a matching PGDG pgBackRest package. About 20 scripts and tests mention IMAGE_TAG. Earlier rollouts of this kind showed write gaps of 2.5 s, 3.8 s and 16 s.
