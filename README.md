# postgres-ha-lab

PostgreSQL 18 runs on one PC in a four-node kind cluster under WSL. Patroni manages one primary and two streaming replicas. pgBackRest sends backups and archived WAL to Garage, an S3-compatible object store in the same cluster. The workers share a physical host, and Garage has a single local data volume. [Requirements](SPEC.md)

The assessment lists S3, GCS, Azure Blob and in-cluster MinIO. This submission uses Garage through its S3-compatible API to keep the backup path on the local PC. [Storage decision](docs/decisions/0004-object-store.md)

## Architecture

Clients use role-based Services. After a promotion, the new primary serves writes through the same endpoint. Each database pod has its own volume. During healthy operation one synchronous standby confirms commits.

```mermaid
flowchart TB
    app["Application"]
    api["Kubernetes API / Patroni leader lock"]
    subgraph live["pg-ha namespace"]
        rw["pg-primary"]
        ro["pg-replica"]
        subgraph db["PostgreSQL StatefulSet / Patroni on each pod"]
            primary["Current primary"]
            replicas["Two streaming replicas"]
            primary -->|physical replication| replicas
        end
        rw --> primary
        ro --> replicas
        cron["pgBackRest backup CronJob"]
        store["Garage object store behind nginx TLS"]
        cron -->|read through pgBackRest TLS servers| db
        cron -->|full and incremental backups| store
        primary -->|archive WAL| store
        graf["Grafana"] -->|query| prom["Prometheus"]
        prom -->|scrape Patroni and postgres-exporter| db
        prom -->|scrape| ksm["kube-state-metrics"]
    end
    app -->|writes| rw
    app -->|reads| ro
    db -->|elect leader| api
    store -->|backup and WAL| restore["pg-restore namespace / full restore, PITR or scratch test"]
```

## Run it

Run from the repository root in WSL with Docker, Make, kind, kubectl, jq and OpenSSL available. The validation tools include ShellCheck and kubeconform. [Version pins](versions.env)

    make up           # kind cluster, image build, object store, PostgreSQL, observability
    make test-quick   # static and read-only checks
    make test         # adds live suites; WARNING: they change the running cluster
    make down         # removes pg-restore and pg-ha, keeps the kind cluster

On 26 November a fresh four-node kind cluster on the local PC completed `make up`, `make test` and `make down`. The suite exercised a full restore, and teardown removed both lab namespaces. The PC already had Docker and cached images. [Bring-up](docs/evidence/gap-verification/window3-up.txt), [acceptance tests](docs/evidence/gap-verification/window3-test.txt) and [teardown](docs/evidence/gap-verification/window3-down.txt).
Open the UIs on this PC only: `bash scripts/obs-open.sh` (Prometheus http://localhost:9090, Grafana http://localhost:3000, user admin, password copied to the Windows clipboard).
Restore, switchover and upgrade procedures: [docs/runbook.md](docs/runbook.md).

## What it looks like

Grafana dashboard (leader, replicas, timeline, archiver, WAL, backup age, replication lag):

![Grafana dashboard](docs/images/grafana-dashboard.png)

Prometheus queries for replication lag, taken during the lag tests:

![Prometheus queries](docs/images/prometheus-queries.png)

Resource check of the running cluster, part 1 and part 2 (namespaces, pods, services, Patroni, backups, alerts, TLS):

![Cluster check 1](docs/images/resources-01.png)

![Cluster check 2](docs/images/resources-02.png)

## Where to read more

- [docs/design.md](docs/design.md): RPO, fencing, measured RTO, multi-zone changes, generalisation, determinism, agent-agnostic notes, threat model, AI process
- [docs/known-limitations.md](docs/known-limitations.md): every gap and finding, including failed and partial results
- [docs/decisions/](docs/decisions/0001-sync-vs-async-replication.md): ADRs
- [AGENTS.md](AGENTS.md): rules for any AI agent

## Honest status

The final live check on 25 November 2026 showed one primary, two streaming standbys with zero reported lag, and four Ready kind nodes. [Final cluster health](docs/evidence/ITEM30-final-8swvNeLT/final-health.txt)

| Drill | Observed result |
|---|---|
| Primary pod loss | A quick restart kept the original leader. In a second drill the worker remained online but was cordoned to delay replacement of the deleted pod. A standby promoted automatically, writes resumed through the same Service, and all 151 acknowledgements survived. The longest gap was 22.891 s. [Quick restart](docs/evidence/ITEM30-FO-1-retry-20261125T0605Z.txt) and [delayed replacement](docs/evidence/gap-verification/pod-loss-confirmed.txt) |
| Primary worker or storage loss | A replica promoted automatically in both drills. The longest gaps between acknowledged writes were 32.048 s for worker loss and 15.095 s for storage loss. All checked acknowledgements survived. [Worker drill](docs/evidence/ITEM30-FO-2-dNvaKPVM/result.txt) and [storage drill](docs/evidence/ITEM30-FO-3-jDYQz4qD/result.txt) |
| Fencing and rejoin | At most one pod was writable across 26 sampling rounds. In the divergence drill the former primary rejoined using pg_rewind. [Fencing](docs/evidence/ITEM30-final-8swvNeLT/fo-split-brain.txt) and [rejoin](docs/evidence/ITEM30-final-8swvNeLT/fo-rejoin.txt) |
| Backup and recovery | A controller-triggered backup passed verification. Full restore matched the 1,000-row checksum on all three pods. PITR retained all 500 pre-target rows and zero post-target rows. The socket-only scratch restore passed after its startup fix. [Backup](docs/evidence/ITEM30-final-8swvNeLT/bk-cron-live.txt), [full restore](docs/evidence/ITEM30-final-8swvNeLT/rs-full.txt), [PITR](docs/evidence/ITEM30-final-8swvNeLT/rs-pitr.txt) and [scratch restore](docs/evidence/ITEM30-final-8swvNeLT/rs-restore-test-retry.txt) |

**Follow-up verification**

- An isolated three-member cluster completed a rolling PostgreSQL 18.6-to-18.7 upgrade with zero missing acknowledged writes. [Upgrade rehearsal](docs/evidence/gap-verification/minor-upgrade.txt)
- Both streaming replicas now verify the primary certificate against the mounted CA. A lagging replica fetched archived WAL and resumed streaming after the slot cap released its required segment. [TLS check](docs/evidence/gap-verification/tls-after.txt) and [slot recovery](docs/evidence/gap-verification/slot-recovery.txt)
- Prometheus recorded all five configured alerts firing. For BackupTooOld, firing overlapped a measured scheduled-backup age above 36 hours. [Alert history](docs/evidence/gap-verification/alert-history-detailed.txt) and [backup-age evidence](docs/evidence/gap-verification/alert-36h.txt)
- All 84 Kubernetes resources passed strict kubeconform validation. Both formerly stale backup checks passed, including a new full backup while retention held the full count at two. [Manifest validation](docs/evidence/gap-verification/manifests.txt), [backup configuration](docs/evidence/gap-verification/backup-static.txt) and [retention-aware schedule check](docs/evidence/gap-verification/backup-schedule.txt)

**Backup and rollout checks**

- The Job scheduled for 02:00 UTC started at 03:44:40 UTC and finished at 03:45:18 UTC with a verified backup. The 23-hour catch-up window allows a missed local run to start later that day. The evidence establishes catch-up and backup verification. Starting during the scheduled minute was not observed. [Controller evidence](docs/evidence/gap-verification/daily-catchup.txt)
- The updated proxy passed the S3 write, read and delete test under the deployed ingress policy. The database rollout preserved all 262 acknowledged writes. Both the WAL and scratch restore checks passed. [Object-store test](docs/evidence/gap-verification/secure-store-job.txt), [rollout](docs/evidence/gap-verification/secure-rollout.txt) and [scratch recovery](docs/evidence/gap-verification/secure-scratch.txt)
- The locally built, unprivileged nginx proxy has all nine pinned Alpine security updates. Its scan reported zero findings. The PostgreSQL r4 scan still reported one critical and 102 high findings. Trivy lists no vendor fix for any of those 103 findings. [Proxy package check](docs/evidence/gap-verification/proxy-patch-packages.txt), [proxy scan](docs/evidence/gap-verification/proxy-patch-scan.txt), [PostgreSQL scan](docs/evidence/gap-verification/patched-scan.txt) and [vendor-fix counts](docs/evidence/gap-verification/patched-fixability.txt)
- On the original kind cluster, all three PostgreSQL r4 pods reached 4/4 ready and the patched object store reached 2/2. Patroni reported one leader and two streaming replicas. Primary writes, replica reads, S3 operations and WAL archiving passed. A fresh Job from the backup CronJob template completed pgBackRest verification. [Rollout and backup](docs/evidence/gap-verification/item2-original.txt), [topology](docs/evidence/gap-verification/item2-topology.txt), [routing](docs/evidence/gap-verification/item2-endpoints.txt), [S3](docs/evidence/gap-verification/item2-s3.txt) and [WAL](docs/evidence/gap-verification/item2-wal.txt).
- The one-time backup on 26 November started at 17:21:02 Dhaka time, two seconds after its scheduled time. The Job completed in 20 seconds and pgBackRest verification passed. [Backup evidence](docs/evidence/gap-verification/pg-ha-extra-20261126-1121.txt)
