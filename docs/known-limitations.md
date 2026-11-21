# Known limitations

Each item says how it was found. Items marked "not tested" are open questions, not claims.

## Backup and recovery
- WAL archiving works (BK-1, docs/evidence/BK-1.txt), but no base backup exists yet (Phase 3). Whether a replica that
  falls behind past `max_slot_wal_keep_size` can now catch up from the archive was not tested; until it is tested it
  needs `patronictl reinit` (manual). Observed 3 times (REP-3 drill, runs 1 to 3).
- On the rebuilt cluster the archiver failed 6 times on pg-ha-0 before the backup sidecar created the stanza, which
  happens at its first check about 60 s after it starts (docs/evidence/BK-1-archiver-first-start.txt). Archiving
  recovered without manual action. The other pods were not looked at, and tests/bk-wal.sh does not detect this:
  it only checks that failed_count does not grow during its own run.
- Archiving fails while the object store is down, so `pg_wal` grows on the 2 GiB volume. Not tested.
- `archive_timeout` is unset, so a quiet cluster can leave its latest WAL segment unarchived. Not tested.

## Replication and disk
- During a silent network partition of a lagging replica, the primary's checkpoint waits on that
  replica's walsender (ReplicationSlotDrop) and `pg_wal` grows by the volume written, because no WAL
  is removed until the checkpoint completes. Measured: 545 MB to 753 MB in 60 s with 208 MB written.
  `wal_sender_timeout` (1 min) did not end the wait. The cap bounds retention only after the
  checkpoint completes. Longer partitions were not tested. Mitigations not tested yet:
  `tcp_user_timeout` on the primary; an alert on `pg_wal` size (Phase 4); PVC sizing.

## Failover and fencing
- Fencing is software only (leader lock plus self-demotion). kind has no hardware watchdog, so a
  hung Patroni process on a partitioned node is not covered (ADR-0003).
- The split-brain test samples the three pods about 0.3 s apart. It shows no sustained overlap of
  two writable primaries; it is not a proof for single instants. The guarantee rests on the lock design.
- A crashed primary pod can restart in place before the lock expires, so no promotion happens
  (FO-1, RTO 6.7 s). A promotion is forced only by node loss (FO-2) or storage loss (FO-3).
- FO-2, first run: all 44 acknowledged writes were reported missing. The rerun passed with the same
  data and a more careful read. The first run's probe log was not saved, so the cause is unproven
  (my best guess is a read error in the test helper). Kept as FO-2-run1-FAILED.txt.

## Configuration
- The `pg_hba` rules exist twice: in the local Patroni file (new clusters) and in the DCS config
  (set with `patronictl edit-config`). They match today; which one is effective was not tested.

## Environment
- All "nodes" run on one laptop (kind), so failures are simulated, not independent. Zones are labels.
- Node loss is `docker kill` of a kind node; network partitions are nftables drops on the node.

## Degraded synchronous mode
- If both replicas are unreachable, commits stall for about wal_sender_timeout (61 s measured) before
  Patroni falls back to asynchronous. If the primary is then lost, no replica is promoted
  automatically (Patroni synchronous mode); recovery waits for the old primary to return, or for a
  manual promotion that accepts data loss. Measured in tests/rep-degraded-sync.sh. This is a
  deliberate trade of availability for RPO 0.
- A silent partition of a replica delays the primary's detection by wal_sender_timeout; a shorter
  value was not tested.

## Object store (Phase 3, ADR-0004, ADR-0005)
- Single node: Garage runs as one pod with `replication_factor = 1` on one local-path volume
  (`data-objstore-0`, 2 GiB). WAL archive and backups share fate with the cluster: losing the node or
  deleting the volume loses them. As far as I know a local-path volume is tied to the node that created
  it (kind-worker here); the volume was not inspected and node loss of the store was not tested. A real
  deployment needs a cloud bucket (ADR-0004).
- Store size: the volume is 2 GiB and the init script sets the Garage layout capacity to 1 GiB
  (CAPACITY_BYTES default). What happens when WAL and backups fill the store was not tested.
  Found by reading k8s/objstore/30-statefulset.yaml and scripts/objstore-init.py.
- TLS certificates are generated at deploy time, valid for 825 days, with no rotation procedure.
  The CA private key exists in a temporary directory on the host disk while the server certificate is
  signed and is removed with `rm`, which is not a secure erase. Expiry behaviour was not tested.
- If the `objstore-credentials` Secret is deleted and regenerated while Garage's volume persists, the
  init script sees the access key id as present and does not update the stored secret, so pgBackRest
  would fail to authenticate. Found by reading scripts/objstore-init.py. Not tested.
- The init script depends on the Garage v2.5.0 admin API (`/v2/...`). Garage's own specification
  warns that this API may change. Not tested on other versions.
- nginx and Garage share one pod. S3 and admin traffic both pass through the one nginx container, and
  the hop from nginx to Garage is plain HTTP on the pod's loopback, by design (ADR-0005).
- The Service is a plain ClusterIP Service, so per-pod DNS names (`objstore-0.objstore`) do not
  resolve. Nothing uses them.
- `db_engine = "sqlite"` was chosen from memory of Garage's documentation for crash safety. It was not
  verified or measured.
- Not shown in the cluster yet, only in Docker (docs/evidence/ADR-0005-init-spike.txt and
  ADR-0005-verify-spike.txt): init repeatability, restart on the volume, rejection of a hostname that is
  not in the certificate, a 100 MB transfer. Update this line when they are tested.
- Only linux/amd64 images were inspected. The registry digests matched the pinned digests for both
  images (docs/evidence/OBJ-1.txt), but nothing was run on another architecture.
- Observed: one readiness-probe failure on port 3900 (connection refused) during the first start of
  `objstore-0`, then ready with 0 restarts. The cause was not investigated.
- The access key ID of the pgBackRest key appears in Garage's request logs (docs/evidence/OBJ-2-leak-diagnosis.txt, ADR-0005 amendment 1).
