# ADR-0001: Synchronous replication with one sync standby

Status: Accepted

## Context
The brief asks us to choose between synchronous and asynchronous replication and to state the RPO.

## Options
1. Asynchronous. Fastest commits. A failover can lose the last commits that had not reached a replica, so the RPO is greater than zero and depends on lag.
2. Synchronous, strict mode. RPO is 0 for acknowledged commits. If no sync standby is available, writes block.
3. Synchronous, non-strict mode (Patroni `synchronous_mode: true`, `synchronous_mode_strict: false`, `synchronous_node_count: 1`). RPO is 0 while a sync standby exists. If every replica is down, Patroni falls back to asynchronous so the primary keeps accepting writes.

## Decision
Option 3. With synchronous mode on, Patroni only promotes the current sync standby, so a promoted node has every acknowledged commit.

## Consequences
- RPO is 0 for acknowledged commits while at least one sync standby is healthy.
- During the degraded state (no sync standby), the RPO is bounded only by replication lag. This is a documented risk, and the alert "no synchronous standby" covers it.
- Commit latency includes one network round trip to the standby, and a slow standby slows writes.
- To be measured and recorded in `docs/evidence/REP-2.txt`: commit latency with and without synchronous mode.

## Amendment 2026-11-20: measured degraded behaviour
Measured with tests/rep-degraded-sync.sh (evidence: docs/evidence/ADR1-degraded*.txt).
- With both replicas cut off from the primary (API access kept), commits stalled for about 61 s, close
  to wal_sender_timeout (1min), before Patroni switched to asynchronous (empty
  synchronous_standby_names). Writes then resumed and the replicas fell behind.
- When the primary's node was then powered off, neither replica took over (first run: about
  3.5 minutes until the node was restarted). Both logged that they were not the healthiest node.
  Patroni's documentation describes this case: with no suitable standby, a failed primary is not
  replaced, and the old primary is promoted when it returns. The log lines do not name the reason;
  the match with the documentation is my reading.
- After the node returned, the old primary became leader again and all acknowledged writes were
  present on all three nodes; synchronous mode came back on its own.

Consequences:
- RPO is 0 for acknowledged commits while promotion can only go to the synchronous standby. In the
  degraded state, commits acknowledged since the fall back exist only on the primary, so losing the
  primary's storage in that state (a double failure) would lose them.
- Price: with no synchronous standby, a lost primary is not replaced automatically; recovery waits
  for the old primary to return or for an operator to promote a replica by hand, accepting data loss.
- Alternatives considered, not adopted: synchronous_mode_strict (writes block instead of falling
  back to async) and synchronous_mode off (failover always possible, RPO above 0).
