# Design

PostgreSQL 18 with Patroni (Kubernetes API as DCS) and pgBackRest to an in-cluster S3-compatible store, on a four-node kind cluster
(one control plane, three workers labelled as three zones). Requirements: [SPEC.md](../SPEC.md). Decisions:
[ADR-0001](decisions/0001-sync-vs-async-replication.md), [ADR-0003](decisions/0003-leader-election-and-fencing.md).
Gaps: [known-limitations.md](known-limitations.md). Procedures: [runbook.md](runbook.md).
Numbers come from the evidence files named next to them; anything not measured says so.

## 1. Synchronous replication and RPO

Patroni `synchronous_mode: true`, `synchronous_mode_strict: false`, one sync standby (ADR-0001).
- RPO is 0 for acknowledged commits while a sync standby exists, because Patroni promotes only the sync standby.
- Degraded case, measured (docs/evidence/ADR1-degraded*.txt): with both replicas cut off, commits stalled about 61 s to 63.6 s until Patroni fell back to
  asynchronous (65 s after the cut). Commits acknowledged after that exist only on the primary.
- Price: with no sync standby a lost primary is not replaced automatically; recovery waits for the old primary or a manual promotion that accepts data loss.
- Not adopted: strict mode (writes block) and asynchronous mode (RPO above 0).

## 2. Fencing and leader election

ADR-0003. The leader key is a Kubernetes object, so one pod holds it. `ttl: 30`, `loop_wait: 10`, `retry_timeout: 10`.
- Fencing is software only: a primary that cannot renew the key demotes itself. No STONITH, no watchdog (kind has none).
- FO-4 (docs/evidence/FO-4.txt): a primary cut off from the API demoted itself, a direct write to it was rejected, a replica was promoted, the old primary rejoined.
  The test samples the pods about 0.3 s apart, so it shows no sustained overlap, not a proof for single instants.
- FO-5: after divergence the old primary rejoined with pg_rewind, and five divergent rows disappeared, with no manual step.

## 3. Measured RTO and method

A probe pod inserts a timestamped row every 100 ms through the `pg-primary` service. RTO is the largest gap between two acknowledged writes
(tests/lib/probe.sh, function analyze_probe). Each row is one run, not a distribution.

| Event | Largest write gap | Evidence |
|---|---|---|
| Primary pod killed (FO-1) | 6731 ms (target 60 s) | docs/evidence/FO-1.txt |
| Primary node stopped (FO-2) | 33420 ms (target 90 s) | docs/evidence/FO-2.txt |
| Primary storage lost (FO-3) | not shown here | docs/evidence/FO-3.txt |
| Rolling update adding the exporter sidecar | 2544 ms, 0 acknowledged writes missing | docs/evidence/OBS-1-exporter-rollout.txt |
| Rolling update, TLS step 1 | 3772 ms, 0 missing | docs/evidence/SEC-2-step1.txt |
| Planned switchover | 16047 ms, 0 missing | docs/evidence/OPS-3-switchover.txt |

A crashed primary pod can restart in place before the lock expires, so FO-1 promoted nobody. The rolling updates moved the timeline by 3 each time; the cause was not investigated.

## 4. What changes on a real multi-zone cluster

- Zones here are labels on kind nodes on one laptop. Real zones are independent failure domains, so FO-2 and the partitions become real events.
- A watchdog can back the software fencing. kind has none.
- The object store is one Garage pod on one local-path volume, so backups share fate with the cluster ([ADR-0004](decisions/0004-object-store.md)). A real system uses a cloud bucket.
- local-path volumes are tied to a node. Real clusters use zone-aware network volumes, and pod spread must match volume placement.
- Certificates are generated at deploy time (825 days, no rotation). A real cluster needs a CA with rotation, and verify-ca replication (dropped here).
- NetworkPolicy and Pod Security were tested on Calico in kind only.

## 5. Generalisation

If the data store were Redis with Sentinel or Vault with Raft. This is design reasoning, not tested.
- Reused almost unchanged: the Makefile and scripts (cluster-up, secret generators, image pattern), namespace, RBAC and Service shapes, PodDisruptionBudget and spread,
  the observability stack (Prometheus, Grafana, rules, kube-state-metrics), NetworkPolicy and Pod Security checks, the write probe with another client, the evidence method.
- Rewritten: the image, the Patroni config, the exporter and alerts, backup and restore (pgBackRest is PostgreSQL specific), the failover tests, the replication ADR, the TLS wiring.
- Sentinel keeps its own quorum and Vault Raft its own leader election, so the Kubernetes-API-as-DCS choice would not apply.

## 6. Determinism

- Pinned in versions.env: tools, kind node image, Calico, the PostgreSQL base image (tag and digest), Patroni (image/requirements.lock), the pgBackRest package, the object store and monitoring images (tag and digest).
- Images are loaded into kind by name:tag because the digest form does not resolve in the nodes (known-limitations), so the digest is checked on the host only.
- Not deterministic: generated secrets and certificates, timelines, which pod leads, timings, and Docker Hub and apt downloads at build time.
- Every live result in docs/evidence/ is one run. Failed runs are kept under -FAILED names.

## 7. Agent-agnostic

[AGENTS.md](../AGENTS.md) is the playbook for any AI agent: read SPEC and ADRs first, test before code, everything as code, pinned versions, no secrets, evidence per phase,
conventional commits, no co-author trailers. Tests are plain bash (`tests/*.sh`), so a human or any agent runs them the same way.

## 8. Threat model

Scope: the pg-ha and pg-restore namespaces in one kind cluster on one laptop. Assets: database contents, database and replication passwords, the object store key, TLS keys, the Grafana admin password.

| Threat | Control | Evidence | Gap |
|---|---|---|---|
| Two primaries (split brain) | Leader key in the Kubernetes API, self-demotion, sync standby | FO-4 | Software fencing only, no watchdog |
| Traffic sniffed or altered inside the cluster | `ssl on`, hostssl rules only, scram-sha-256 | SEC-2 (docs/evidence/SEC-2-accepted.txt) | Streaming replicas verify the primary certificate against the mounted CA; REST API on 8008 is plain HTTP; no certificate rotation |
| Another pod reaches the database or the store | Ingress NetworkPolicies on the Postgres pods and the object store | SEC-3 (docs/evidence/SEC-3.txt) | No egress policy; Grafana, Prometheus and pg-restore unrestricted; labels not identity |
| Over-broad Kubernetes rights | Narrow Patroni Role; read-only kube-state-metrics ClusterRole without Secrets | SEC-4 | Patroni can delete ConfigMaps (need not tested); the exporter is a superuser |
| Container breakout | Restricted Pod Security, non-root, drop ALL, seccomp | SEC-5 | readOnlyRootFilesystem not set |
| Vulnerable images | trivy scan, counts recorded | SEC-6 | Patched nginx scan reported zero findings. PostgreSQL r4 retained one critical and 102 high findings with no listed vendor fix. Garage yielded no analyzable target |
| Secrets in the public repository | Generated at deploy, gitleaks, value and name scans | SEC-1 | Binary files, older history and git-ignored raw logs not covered; screenshots checked by eye only |
| Data loss | WAL archive, backups with verify, restore tests | BK-1 to BK-4, RS-1 to RS-3 | Store shares fate with the cluster; the controller created a delayed Job for the 02:00 UTC schedule and pgBackRest verified it |
| Copies of live secrets left in pg-restore | Deleted by scripts/restore-down.sh | ADR-0006 | Present until someone runs it |
| Unnoticed failure | Five Prometheus alert rules | OBS-2, OBS-3 | No Alertmanager, nothing is sent; all five rules reached firing in Prometheus |

Not tested: a hostile pod inside pg-ha, certificate expiry, a stolen Secret, denial of service on the API server, a compromised node. This models a lab setup and is not a security assessment.

## 9. AI process

Logs are described in [ai-process/LOGGING.md](ai-process/LOGGING.md).
1. The human decides scope, cuts and order. The assistant gives facts, options and costs and recommends only when asked.
2. The assistant never runs anything and sees the repository only through pasted output. The human runs every command.
3. Test first. A failing run is kept under a -FAILED name with a header saying which red lines are expected. A check that cannot fail on a healthy system gets a control.
4. Two failed attempts at one step stop the work and trigger a report.
5. Every prediction is marked and checked afterwards; several were wrong (line counts, PASS counts, one jq filter), and the wrong ones stayed in the record.
6. Every report says what was not verified. Gaps go into docs/known-limitations.md with their reason.
7. Commits are by file name with a count check, name and secret scans, and no AI co-author trailer. Pushes happen when the human decides.
8. Logs are captured from the chat, redacted by script and not edited by hand. Redaction also replaces two names (see LOGGING.md).
