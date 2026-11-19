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
