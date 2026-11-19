# ADR-0004: S3-compatible object store inside the cluster

Status: Proposed. Final choice after checking which image is pullable and pinnable (Phase 3).

## Context
The brief requires backups and WAL archives in object storage. A reviewer must be able to reproduce the setup without a cloud account.

## Options
1. MinIO in the cluster. Well known S3 API, easy to run for tests.
2. Garage. Small, S3-compatible, open source.
3. A real cloud bucket (S3 or GCS). Closest to production, but needs the reviewer's account and credentials.

## Decision
Start with MinIO if a pinned image can be pulled. Fall back to Garage if not. A cloud bucket is the production recommendation, documented but not used here.

## Consequences
- pgBackRest talks to a single S3 endpoint setting, so moving to a cloud bucket later changes configuration only.
- The in-cluster store has no durability beyond the cluster. A single in-cluster store is not a real backup target, and this goes in `known-limitations.md`.
- Bucket credentials are generated at `make up`.
