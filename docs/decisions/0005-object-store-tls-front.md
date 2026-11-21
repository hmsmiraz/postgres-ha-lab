# ADR-0005: TLS front and API-driven initialisation for the in-cluster object store

Status: Accepted (2026-11-21). OBJ-2 passes in the cluster (docs/evidence/OBJ-2.txt) with the log-check change of amendment 1; the access key id appears in Garage request logs (known limitation).

## Context
ADR-0004 chose Garage v2.5.0. Three measured facts shape how it is deployed.
1. pgBackRest 2.60.0 failed against plain-HTTP Garage at stanza-create with "TLS error ... wrong version number"
   (docs/evidence/ADR-0004-garage-local-spike.txt). Garage's cookbook says a reverse proxy is the way to provide TLS, and a
   third-party quickstart says Garage's S3 API has no TLS. The v2.5.0 configuration reference was not checked.
2. The Garage image has no shell (sh not found, exit 127), so a Job cannot chain `/garage` CLI commands. The v2.5.0 admin API
   offers the needed operations (docs/evidence/ADR-0005-garage-admin-api-schemas.txt).
3. Garage accepts `GARAGE_RPC_SECRET` and `GARAGE_ADMIN_TOKEN` as environment variables, and started with a garage.toml that
   holds neither (docs/evidence/ADR-0005-verify-spike.txt).

## Options
1. nginx (unprivileged) as a sidecar in the Garage pod, terminating TLS. Chosen.
2. A separate proxy Deployment. Not tried: one more object and one more network hop.
3. Plain HTTP between pgBackRest and Garage. Not possible with this pgBackRest (measured, see above).
4. Another S3 server with native TLS. Not evaluated. Caddy 2.11.9 and HAProxy 3.0.31 were also listed as proxy candidates
   (docs/evidence/ADR-0005-proxy-tags.txt); their newest tags were 5 and 2 days old at the time and they were not evaluated further.

## Decision
- One pod, two containers: Garage (uid 10001) and nginx-unprivileged 1.30.6-alpine (uid 101, pinned by digest in versions.env),
  plus an init container that creates the data directories.
- Garage's S3 (3910), admin (3913) and RPC (3901) ports bind to loopback. nginx serves TLS on 3900 (S3) and 3903 (admin). The
  Service exposes only those two ports.
- Certificates are generated at deploy time by scripts/gen-objstore-secrets.sh with openssl. The CA private key exists only in a
  temporary directory while the server certificate is signed and is removed before the Secret is written, so the cluster holds
  ca.crt, tls.crt and tls.key only. The server certificate names the Service in four forms and is valid for 825 days.
- Secrets: objstore-credentials, objstore-admin and objstore-tls, all generated once and never printed. Garage takes its two secrets
  from environment variables through secretKeyRef, so no ConfigMap holds a secret.
- Bucket, key and permissions are created by the Job objstore-init, which runs scripts/objstore-init.py from the pg-ha image
  against the admin API over verified TLS. It acts only on what is missing. The pgBackRest key gets read and write, not owner.
- Tests: tests/obj-image.sh (OBJ-1), tests/obj-secrets.sh (generator), tests/obj-s3.sh (OBJ-2), scripts/verify-objstore-manifests.sh (static).

## Measured
- With the TLS front, pgBackRest wrote, listed, read and deleted over verified TLS in the cluster (docs/evidence/OBJ-2.txt).
- Negative controls: without the CA file pgBackRest rejects the certificate, in the cluster (OBJ-2.txt) and in Docker
  (docs/evidence/ADR-0005-tls-local-spike.txt); a hostname that is not in the certificate is rejected (Docker only,
  docs/evidence/ADR-0005-verify-spike.txt).
- In the cluster, ports 3910, 3913 and 3901 are closed on the pod IP and 3900 and 3903 are open through the Service (OBJ-2.txt).
- A 100 MB offline backup (977 objects) went through the front in about 20 s (Docker only, ADR-0005-verify-spike.txt).
- The init script ran twice with the second run reporting everything as already present, and after recreating the containers
  on the same directories (Docker only, ADR-0005-init-spike.txt and ADR-0005-verify-spike.txt).

## Consequences
- One Garage node with replication_factor 1. The in-cluster store has no durability beyond the cluster (see ADR-0004).
- Traffic between nginx and Garage is plain HTTP on the pod's loopback, by design.
- The certificate has no rotation and expires after 825 days. rm of the CA key directory is not a secure erase.
- Regenerating a Secret does not update a key that Garage already holds: the init script only checks that the key id exists.
- The init script depends on the v2.5.0 admin API, whose specification warns that it may change.
- The Service is a plain ClusterIP Service, so per-pod DNS names do not resolve.
- db_engine = "sqlite" was chosen from memory of Garage's documentation for crash safety. It was not verified or measured.
- Not yet shown in the cluster: init repeatability, a pod restart on its PVC, a hostname-mismatch rejection, a large transfer.
- Only linux/amd64 was inspected.

## Amendment 1 (2026-11-21): the log-leak check and the access key id
Found by: the first OBJ-2 run scanned logs with `producer | grep -q`, which can pass without looking
(docs/evidence/OBJ-leak-pipefail-hazard.txt). With the scan rewritten to `grep -c`, the check failed
(docs/evidence/OBJ-2-leak-FAILED.txt). Per-source counts are in docs/evidence/OBJ-2-leak-diagnosis.txt: the access key id
appears in Garage's request log (INFO-level request lines, including those for pgBackRest calls; how the number of lines relates to the number of requests was not checked). The secret access key, the admin
token and the rpc secret had no matches in any log that was scanned.

Old check: none of the four generated values (access key id, secret access key, admin token, rpc secret) appears in any
repo file, ConfigMap or log.

New check (human decision, option A):
- The three access-granting values (secret access key, admin token, rpc secret) appear in no repo file, no evidence file, no
  ConfigMap and no log (init Job, test client, all containers of objstore-0).
- The access key id appears in no repo file, no evidence file and no ConfigMap. It is allowed in Garage's request logs. The test
  prints only a count of those log lines, never the lines.
- A control checks that the log scanner fires on a planted secret value and does not match the access key id.

Why the key id is treated as an identifier: it is sent with every S3 request and names the key. In the S3 protocol a request is
authenticated with a signature made from the secret access key, so the id alone is not a credential. This is the general S3
design and was not tested against Garage.

Options not taken: keep the old check and stop Garage from logging the id (not investigated, would change Garage's logging);
record the failure as a known limitation and leave the test red; keep the id in the scan but ignore Garage's request-log
lines (would hide anything else those lines contain).

Not verified:
- That Garage rejects a request that carries only the access key id. Not tested.
- Whether Garage can be configured not to log the key id. Not investigated.
- Anything beyond container stdout: Garage reports journald and syslog features in its version string, and logs of earlier
  container instances and lines already rotated were not scanned.
- Garage at a higher log verbosity than the default.
- Other pod logs after BK-1: tests/bk-wal.sh scans the Postgres pod logs for all four values.
