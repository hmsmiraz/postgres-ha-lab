# Known limitations

Each item says how it was found. Items marked "not tested" are open questions, not claims.

## Backup and recovery
- No WAL archive or base backups exist yet (Phase 3). Until then a replica that falls behind past
  `max_slot_wal_keep_size` cannot catch up and needs `patronictl reinit` (manual). Observed 3 times
  (REP-3 drill, runs 1 to 3).

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
