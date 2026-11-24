# Known limitations

Each item says how it was found. Items marked "not tested" are open questions, not claims.

## Backup and recovery
- WAL archiving works (BK-1, docs/evidence/BK-1.txt) and base backups exist (BK-2, BK-3). Whether a replica that
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

## Backups, retention and restore (Phase 3, ADR-0002, ADR-0006)
- The BK-2 CronJob (daily 02:00 UTC) did not fire on its own: it was created on 2026-11-21 at about 16:53 UTC, and the 02:00 UTC
  run on 2026-11-22 left no Job and no event (lastScheduleTime was unset at 04:20 UTC). The cause was not found. With a temporary
  schedule of every 2 minutes the controller created a Job about 2 minutes later and it completed (docs/evidence/BK-2-cron-fire.txt),
  so the controller can start this CronJob. The real 02:00 firing is not shown. tests/bk-schedule.sh uses Jobs started by hand from
  the CronJob template.
- concurrencyPolicy Forbid is checked as a setting only. An overlapping run was not tested.
- Job 4 of tests/bk-schedule.sh (broken CA paths) must fail, and it does, but the test does not check why. Found by reading it.
- Retention is retention-full=2 (type count). BK-3 shows the oldest full backup and its incremental are expired. Not tested:
  time-based retention, differential backups, expiry during a restore. After expiry, point-in-time recovery to a time
  before the oldest kept full backup is no longer possible.
- The pgBackRest server certificates are valid for 825 days (to Feb 2029) with no rotation. The CA key is removed with rm,
  which is not a secure erase. Authorisation by certificate name and stanza is configured but not tested, because the
  cluster holds no CA key to sign another name.
- The restore namespace pg-restore holds the live database passwords and the read-write object store key until it is deleted
  (ADR-0006). The restored cluster has the same Patroni system identifier as the live one. Only archive_mode=off keeps it
  from writing into the live archive, and tests/rs-full.sh checks the timeline.
- RS-1 did not cover restoring an older backup, an archive that holds a newer timeline, two restores at the same time, or a
  failed restore script.
- No NetworkPolicy exists. The pgserver port (8432) and the path from pg-restore to the object store in pg-ha are open. SEC-3
  must allow both.
- Observed and not investigated: the second rolling update moved the timeline from 2 to 5 (three promotions in one update),
  and no write probe ran. Overnight, pg-ha-2 failed one liveness probe (about 02:24 UTC) and one readiness probe (about
  04:04 UTC) and pg-ha-0 one readiness probe (about 04:17 UTC), with no restart and no promotion.
- History scan: gitleaks over 34 commits found nothing, a scan for the current secret values found 0 files, and a scan with
  the pre-commit hook's pattern found 0 matches in file content, commit messages, author lines, file paths and refs. Not
  covered: secret values from before the BK-1 rebuild, binary files, and objects that GitHub served before the repository was
  recreated.
- pgbackrest verify (2.60.0) exits 0 even when its report says "status: error" (observed for a backup set that does not exist:
  docs/evidence/BK-4-run2-FAILED.txt, docs/evidence/BK-4.txt) and prints nothing unless --output=text is given. Since ADR-0002
  amendment 2 the backup CronJob script runs "verify --output=text --verbose" and fails the Job unless the exit code is 0 and the
  report has the line "status: ok"; tests/bk-verify.sh shows this live with a missing backup set. Not tested: whether verify
  reports "status: error" for a damaged backup or archive file (only the missing-set error was produced), and a pgBackRest
  version that words the report differently (it would fail the Job, the safe direction).
- Two failure cases of the backup script (verify exits non-zero after a healthy report, and an empty report) were run only
  against a stand-in for pgbackrest in a terminal, and that output is not saved in the repository. The error-report case with
  exit 0 is shown live by Job 2 of tests/bk-verify.sh (docs/evidence/BK-4.txt).
- tests/bk-schedule.sh, tests/bk-retention.sh and tests/rs-full.sh make Jobs from the CronJob template, which now also run
  verify and fail if the report lacks "status: ok". They were not rerun after the script gained the verify step (ADR-0002
  amendments 1 and 2); the final suite rerun (handoff item 30) covers it.

## Phase 4 findings (2026-11-23)
- Log redaction (ADR-0007, rule R2): an encrypted private key whose body follows a blank line is not fully redacted, because the blank line closes the block (not tested). A single plain word of 4 or more letters right after a lone marker is replaced. Other secret shapes in the pushed chat logs were never covered.
- The four monitoring images (Prometheus, postgres-exporter, kube-state-metrics, Grafana) cannot be referenced by digest in pods on this cluster: kind load stores a re-exported manifest, and the registry digest is in no node (docs/evidence/OBS-1-image-local-FAILED.txt). Manifests use name:tag and the digest is checked on the host only (tests/obs-image.sh). Why the object store images did resolve by digest is unknown.
- kind load left four unnamed import-2026-11-23 entries in every node (about 1.7 GB per node) from the digest-form load. They are unused and not removed.
- The names loaded by kind load were not tested across a kind restart.
- The BK-2 CronJob did not fire at 02:00 UTC on 2026-11-22 or on 2026-11-23: at 03:13 UTC on 2026-11-23 the only Job was the 2-minute test run from 2026-11-22 (docs/evidence/BK-2-cron-fire.txt) and the last schedule time had not moved. The cause is unknown and was not investigated yet.
- The history scan counts here (gitleaks over 34 commits, in the Backups section) are older than the scan of 2026-11-22 (43 commits) and the scan before the push on 2026-11-23 (45 commits, all clean). Binary files and secret values from before the BK-1 rebuild are still not covered.
- Live schedule test (tests/bk-cron-live.sh, docs/evidence/BK-2-cron-live.txt, 2026-11-23): with the schedule patched to fire about 3 minutes ahead, the controller created a Job, it completed with "verify ok", and the repository went from 7 to 8 backups. The schedule was restored to 0 2 * * *. This does not explain the missed 02:00 UTC runs of 22 and 23 Nov. The real 02:00 firing is still not shown, and the next one is 2026-11-24 02:00 UTC if the laptop is awake.
- The kube-controller-manager log shows "the server has asked for the client to provide credentials" and "Unauthorized" errors (04:04, 08:10 and 12:21 UTC on 22 Nov, 03:03 UTC on 23 Nov). Their cause and any link to the missed CronJob runs were not investigated.
- Hypothesis, not tested: the WSL VM was paused near 02:00 UTC (probe failures were recorded at about 01:45 and 03:00 UTC). dmesg showed no suspend or resume line.

## Phase 4 observability findings (2026-11-23)
- The Grafana home page showed a "Latest from the blog" box before the news feed was switched off. GF_NEWS_NEWS_FEED_ENABLED is now false in the pod (docs/evidence/OBS-1-ui-fix-live.txt). Whether the box is gone in the browser was not checked, and the cause of the original fetch (pod or browser) was not found.
- The rolling update that added the postgres-exporter sidecar moved the timeline from 5 to 8 (three promotions, leader back on pg-ha-2), like the earlier update (2 to 5). The cause was not investigated. In that one run 0 acknowledged writes were missing, the largest write gap was 2544 ms with 32 failed attempts (docs/evidence/OBS-1-exporter-rollout.txt). No target exists for an update, and one run is not a distribution.
- The postgres-exporter connects as the postgres superuser over the local socket (peer authentication), so a monitoring container holds superuser rights. A least-privilege monitoring role was not built. SEC-4 must decide this.
- kube-state-metrics has a ClusterRole with list and watch only, without secrets, across the whole cluster. Prometheus reads the Patroni metrics port 8008 without a login, and any pod can read it (checked from pg-ha-0). Neither is restricted by a NetworkPolicy, since none exists.
- scripts/verify-bk1-static.sh (phase 3) applies only the __IMAGE__ substitution to k8s/pg/50-statefulset.yaml and compares the file with HEAD. The file now has a second placeholder, __PG_EXPORTER_IMAGE__. The script was not rerun and may be red. Item 30 covers it.
- Patroni resumes a paused WAL replay on a replica within about 3 s (Postgres log "recovery has paused" at 05:30:46, Patroni log "Resuming paused WAL replay" at 05:30:49). A single pause creates a lag shorter than the 15 s scrape interval. tests/obs-rep-lag.sh therefore re-pauses in a loop. Its run history is kept: run 1 (lag not seen), the diagnostic run, run 2 (flawed single read of the paused flag) and run 3 (10 PASS), docs/evidence/REP-4-prometheus*.txt.
- Replication lag in Prometheus was shown only under a deliberate lag on one async replica. On an idle cluster pg_replication_lag_seconds reads 0, and pg_replication_last_replay_seconds grows without writes and is not a lag, so it must not be used for an alert. A lag on the sync standby, a lag caused by a stopped stream, and a lag at the 7-day retention scale were not tested.
- scripts/obs-open.sh does not check whether port 9090 or 3000 is already in use. A second run next to an old port-forward printed "address already in use" for 9090. Dashboards are provisioned from k8s/obs/50-dashboards.yaml, so edits made in the Grafana UI are lost on a restart. The Prometheus volume (2Gi, 7 days of retention) and the memory limits are estimates and were not measured, since metrics-server is not installed.
- OBS-3, ReplicationLag: the alert fires in the promtool unit test (docs/evidence/OBS-3-unit.txt). Under the live replay-pause trigger it reached "pending" but never "firing" in two runs (docs/evidence/OBS-3-ReplicationLag-FAILED.txt with for 30s, OBS-3-ReplicationLag-run2-FAILED.txt with for 15s and a 0.3 s re-pause loop). Patroni resumes paused replay within about 3 s, so the lag dropped below 10 KiB before the "for" time ran out. The cause was not proven. A lag held by a stopped replication stream was not tried. The "for" was lowered from 30s to 15s for this attempt and stays at 15s, so the alert reacts to short lag spikes.
- OBS-3, NoPrimary and SlotRetention are shown only by the promtool unit test on synthetic series (docs/evidence/OBS-3-unit.txt). They were not triggered live, because a real trigger would break the cluster (no primary) or needs a replica about 1 GiB behind (slot retention).
- OBS-3, WalArchiveFailure: with the object store scaled to 0 for about 3 min 25 s, failed_count rose from 0 to 1 at t=159 s and the alert went pending at t=171 s. The test loop stopped at 200 s and printed "never", but the first recovery line shows state=firing, so the alert fired a few seconds later and returned to inactive after about 6 minutes (docs/evidence/OBS-3-WalArchiveFailure-FAILED.txt, 2 PASS and 1 FAIL; the FAIL line is the test's wait being too short, not the rule). The file contradicts itself and was not edited.
- OBS-3, WalArchiveFailure: archiving recovered by itself after the store came back (last archived WAL moved from 000000070000000000000027.partial to 00000008000000000000002D). failed_count rose only once in about 3 minutes, so retries are slow; why was not investigated. A store down for longer, or with a full pg_wal volume, was not tested. The last archived WAL before the test was a .partial file of the older timeline 7, and the cause was not looked at.
- OBS-3, BackupTooOld: fired live only with the threshold lowered to 3600 s in the live ConfigMap (the last backup was about 9 hours old and could not be aged to 36 h). It fired 33 s after Prometheus restarted and cleared after the restore to 129600 (docs/evidence/OBS-3-BackupTooOld.txt). The 36 h threshold itself was not reached live. Prometheus was restarted twice for this test, and its data volume kept the history.
- OBS-3, summary: of the five alerts, one fired live under its real rule (WalArchiveFailure), one fired live with a changed threshold (BackupTooOld), one only reached pending (ReplicationLag), and two are shown only by the promtool unit test (NoPrimary, SlotRetention). No Alertmanager exists, so nothing is sent anywhere.
- SEC-1 (tests/sec-secrets-scan.sh, docs/evidence/SEC-1.txt): gitleaks found 0 leaks over 64 commits and 291 tracked files, and the 10 live secret values were found in no tracked file and no commit. Not covered: binary files, secrets from before the BK-1 rebuild, objects GitHub served before the repository was recreated, untracked files, the git-ignored raw logs, and secrets that were rotated or deleted before the scan.
- SEC-1 checks could not fail on a clean repository, so the proof that they can fail is two controls (a planted token, a known string). Run this test before every push.
- SEC-2: ssl is on and every pg_hba rule is hostssl on all three pods (docs/evidence/SEC-2-step1.txt); clients and walsenders use TLS. The planned sslmode verify-ca for replication was NOT applied (accepted by the human): replicas do not verify the leader's certificate, so a man in the middle inside the cluster is not excluded. Clients get TLS from the server's hostssl rules, not from certificate checks.
- SEC-2: the Patroni REST API on port 8008 stays plain HTTP, and Prometheus and the probes use it.
- SEC-2: the CA key is removed with rm (not a secure erase) and the certificates (825 days) have no rotation.
- SEC-2: the first single-step rollout got stuck, because a restarted replica required TLS from a leader that had none yet (docs/evidence/SEC-2-rollout-FAILED.txt). It was fixed by removing verify-ca and deleting pg-ha-2 by hand. Over both rollouts the timeline moved 8 to 11, and no acknowledged write was lost (6081 and 199 acknowledged, 0 missing).
- SEC-2: whether a Patroni reload applies verify-ca without a restart was not tested.
- SEC-3 (option C, ingress only): NetworkPolicies pg-ha-ingress and objstore-ingress are applied (docs/evidence/SEC-3.txt). A test pod without the allowed labels was blocked from the Postgres ports 5432 and 8008 and from the object store 3900, and the allowed flows worked (12 PASS). Egress is not restricted, and Grafana, Prometheus, kube-state-metrics and the pg-restore namespace have no policy.
- SEC-3 allows are label-based, so any pod in pg-ha that carries app=write-probe, app=prometheus or a Job label is admitted. The 8432 and 3900 flows of the backup Jobs, readiness after a pod restart and kubectl port-forward under the policies were not tested; item 30 reruns the backup suites.
- SEC-3 was applied while the PC was awake and the cluster healthy; a failover under the policies was not rerun.
- SEC-4 (tests/sec-rbac.sh, docs/evidence/SEC-4.txt): Patroni, kube-state-metrics and the default account cannot read Secrets, and Patroni cannot create or delete pods or list nodes (13 PASS). The Patroni Role still allows delete and deletecollection on ConfigMaps; whether Patroni needs them was not tested, because removing a verb risks breaking a failover.
- SEC-4: the postgres-exporter runs as the postgres superuser over the local socket, and kube-state-metrics has a ClusterRole with list and watch on cluster resources (no Secrets). A least-privilege monitoring role was not built.
- SEC-4 checks passed on the first run, so they could not be red first; the admin control (can get secrets: yes) is the only proof that the check can answer yes.
- SEC-5 (tests/sec-psa.sh, docs/evidence/SEC-5.txt): all 21 containers in pg-ha and 3 in pg-restore run non-root, with allowPrivilegeEscalation false, capabilities dropped (ALL) and seccomp RuntimeDefault, and both namespaces enforce the restricted Pod Security Standard (6 PASS). readOnlyRootFilesystem is not set on any container.
- SEC-5: the first run of the test reported 22 false violations because of a jq bug (false // true); the cluster was correct. The failed run is kept as docs/evidence/SEC-5-FAILED.txt.
- SEC-5 checks could not be red first on a correct cluster; the proof they can fail is two controls (a synthetic bad container and a privileged pod rejected by admission).
- Grafana was killed (exit 137) repeatedly at the guessed 384Mi limit during a trivy scan and a cold start. Raised to 768Mi with a startupProbe (docs/evidence/OBS-1-grafana-mem.txt). Measured: heap about 228 MB, working set about 520 MB; page cache makes the raw cgroup number look near the limit. Not tested under load.
- A full PC shutdown and cold start (24 Nov) recovered the Patroni cluster without intervention (timeline 11 to 12, SEC-1 clean afterwards); the 02:00 UTC backup did not run because the PC was off.
- SEC-6 (tests/sec-scan.sh, docs/evidence/SEC-6-FAILED.txt): trivy 0.76.2 vulnerability scan, CRITICAL/HIGH counts: postgres-exporter 0/0, kube-state-metrics 0/11, nginx-unprivileged 5/15, Prometheus 0/2, pg-ha 2/184, postgres base 2/154, Grafana 0/20. None was fixed, and no image is claimed clean.
- SEC-6: the Garage image could not be scanned (no analysable target), so its findings are unknown. The pg-ha image is built on the Debian trixie postgres base and carries most findings; a fix needs new pins, a rebuild, a rollout and a rerun of the suites.
- SEC-6: scan numbers depend on the trivy database of 24 Nov 2026 and on the images pinned on that date. A first all-in-one version of the test crashed the terminal; the final script scans one image per run.
