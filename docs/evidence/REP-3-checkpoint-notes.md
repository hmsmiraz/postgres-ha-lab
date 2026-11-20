# REP-3: lagging replica behind a silent network cut (observed 2026-11-20)

Setup: max_slot_wal_keep_size lowered to 128MB, replica pg-ha-2 cut off with an nftables drop,
24 WAL segments (about 384 MB) generated, then CHECKPOINT on the primary.

Observed (server log is UTC; the test prints local time, UTC+6):
- The slot moved from reserved to unreserved; the primary kept accepting writes.
- The checkpointer waited on IPC/ReplicationSlotDrop; the walsender of the cut-off replica waited
  on Client/ClientWrite. 48 ms after the checkpoint started the primary logged "terminating process
  ... to release replication slot", but that walsender stayed alive.
- The checkpoint completed after 210.9 s, about 43 s after the cut was removed:
  "0 WAL file(s) added, 0 removed, 25 recycled".
- wal_sender_timeout was 1min and did not end the wait. Not yet explained.
- The replica could not catch up (its WAL segment was removed) and needed
  `patronictl reinit` (manual step) in both runs. A WAL archive (Phase 3) is the real fix.

Test errors on my side, not cluster faults: the first three attempts used client timeouts of
30 s, 180 s and 200 s, all shorter than the 211 s the checkpoint needed.

Not yet measured: pg_wal growth under writes while the checkpoint waits; see REP-3-drill.txt.

## Run 3 (tests/rep-slot-disk.sh, evidence in REP-3-drill.txt)
- Checkpointer confirmed waiting on ReplicationSlotDrop while the replica was cut off.
- pg_wal grew from 545 MB to 753 MB in 60 s while the primary wrote 13 segments of 16 MB (208 MB):
  growth equals the volume written. The 128MB cap did not bound pg_wal during the wait.
- The checkpoint completed 37 s after the cut was removed (43 s in the earlier run). Cause of the
  ~40 s not established.
- The WAL file the replica needed (000000070000000000000055) was gone afterwards; the replica
  could not recover and needed `patronictl reinit` (third occurrence).
- Not tested: longer partitions; tcp_user_timeout or keepalive settings on the primary as a fix.
