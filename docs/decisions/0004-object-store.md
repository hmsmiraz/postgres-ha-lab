# ADR-0004: S3-compatible object store inside the cluster

Status: Accepted (2026-11-21). Garage v2.5.0 behind a TLS front (ADR-0005). OBJ-2 passes in the cluster with the log-check change of ADR-0005 amendment 1 (docs/evidence/OBJ-2.txt).

## Context
The brief requires backups and WAL archives in object storage. A reviewer must be able to reproduce the setup without a cloud account.

## Options
1. MinIO in the cluster. Rejected. On 2026-11-21 anonymous pulls of `minio/minio:RELEASE.2025-09-07T16-13-09Z` failed on Docker Hub ("pull access denied") and on quay.io ("unauthorized"). That tag is the newest community release as far as I found. Unaffiliated re-uploads exist, but their publishers are not MinIO and the upstream project is archived, so we do not pin them. Evidence: `docs/evidence/ADR-0004-image-probe.txt` and `-run1.txt`.
2. Garage (Deuxfleurs). Chosen. Pulled anonymously from Docker Hub for v2.2.0, v2.4.1 and v2.5.0 (same evidence files).
3. A real cloud bucket (S3 or GCS). Closest to production, but needs the reviewer's account and credentials. Production recommendation only; not used here.
4. Other S3-compatible stores (RustFS was mentioned in an article as a MinIO replacement). Not evaluated, because Garage already satisfied the rule in the first version of this ADR.

## Decision
Garage v2.5.0, pinned in `versions.env` as `OBJSTORE_IMAGE` with tag and digest. The newest tag that pulled was chosen for security fixes. The fallback is v2.4.1 if the S3 tests fail on v2.5.0. Only the digest is enforced by Docker; the tag is a label for humans. Test: `tests/obj-image.sh`, evidence: `docs/evidence/ADR-0004-image-pin.txt` (and the FAILED run before the pin existed).

## Consequences
- pgBackRest uses a single S3 endpoint setting, so moving to a cloud bucket later changes configuration only.
- The in-cluster store has no durability beyond the cluster. A single in-cluster store is not a real backup target; this goes in `known-limitations.md`.
- Bucket credentials are generated at `make up`.
- Garage is AGPLv3 and is run unmodified as a separate service.
- Measured 2026-11-21: pgBackRest 2.60.0 against plain-HTTP Garage failed with a TLS error (wrong version number). With a TLS front it works, with certificate verification on. See ADR-0005, docs/evidence/ADR-0004-garage-local-spike.txt and docs/evidence/ADR-0005-tls-local-spike.txt.
- Measured 2026-11-21: the Garage image has no shell (sh not found, exit 127), so setup runs through the admin API from the pg-ha image (ADR-0005, docs/evidence/ADR-0005-init-spike.txt).
- Only linux/amd64 was pulled and inspected. The reference was checked against the registry digest for the tag, not on other architectures.
- v2.5.0 was published on 2026-10-24. No release notes were found for 2.3 to 2.5, so compatibility with v2.2.0 behaviour is not assumed.
