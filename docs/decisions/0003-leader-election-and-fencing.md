# ADR-0003: Patroni with the Kubernetes API for leader election and fencing

Status: Accepted

## Context
Two primaries must never accept writes at the same time. The brief asks us to explain the fencing approach and the election mechanism.

## Options
1. Patroni with the Kubernetes API as its DCS. The leader key lives in a Kubernetes object, and the leader renews it every loop.
2. Patroni with etcd or Consul. A separate consensus cluster to run, secure and back up.
3. A custom controller. Most flexible and hardest to defend.

## Decision
Option 1.

- Election: a pod acquires the leader key through the Kubernetes API, which is backed by etcd. Only one pod can hold it.
- Lease: `ttl: 30`, `loop_wait: 10`, `retry_timeout: 10`, so `loop_wait + 2 * retry_timeout <= ttl`. A leader that cannot renew the key within the TTL demotes itself.
- Fencing: software based. A primary cut off from the API demotes itself (stops accepting writes) before the TTL expires and another pod can take over. There is no STONITH.
- Extra protection: with synchronous mode on (ADR-0001), a stale primary that keeps running cannot get a sync acknowledgment from the standby that is now following the new primary, so its commits block.
- Rejoin: the old primary uses pg_rewind (needs `wal_log_hints` or data checksums), and re-clones from the new primary if rewind fails.

## Consequences
- A hung Patroni process on a partitioned node is not covered by a hardware watchdog, because kind has none. Documented in `known-limitations.md`. On real nodes we would enable a watchdog.
- The pods need RBAC on the leader and config objects only.
- Failover time depends on the TTL, which trades faster failover against more false failovers on a busy API server.
