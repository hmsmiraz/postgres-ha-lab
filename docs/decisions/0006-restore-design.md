# ADR-0006: restore into a fixed scratch namespace as a 3-pod Patroni cluster

Status: Accepted (Phase 3).

## Context
RS-1 asks for a full cluster restore into an empty namespace by one script. RS-2 (point in time) and RS-3 (restore test) reuse it.

## Options
1. A single Postgres pod that runs pgbackrest restore. Smallest, but it restores data and not a cluster.
2. A 3-pod Patroni cluster whose bootstrap runs pgbackrest restore. Closer to the SPEC wording, larger.
3. Option 1 first, option 2 later.

## Decision
Option 2. The namespace is the fixed scratch namespace pg-restore, created by scripts/restore-full.sh and removed by
scripts/restore-down.sh, which refuses any other namespace name. Patroni runs a custom bootstrap method that calls
pgbackrest restore from the repository of the live stanza. The restored cluster runs with archiving off
(archive_mode=off and the restore option archive-mode=off), so it never writes into the live repository. It has no
post_bootstrap step, because the restored data already holds the application role. The two replicas are created from the
restored leader by Patroni's normal base backup. The same pinned image is used, so no new image.
The Secrets pg-credentials and objstore-credentials are copied from pg-ha without printing them, and only ca.crt of
objstore-tls, as the Secret objstore-ca. The restored roles carry the live passwords, so the restored cluster needs them.

## Consequences
- pg-restore holds the live database passwords and the read-write object store key until the namespace is deleted.
  The two protections against a write into the live archive are archiving off and the timeline check in tests/rs-full.sh.
- The restored cluster uses about 2.3 GB of memory limits at most on a laptop with about 5 GB available.
- RS-2 and RS-3 reuse the namespace and the script with other restore options.
- NetworkPolicies of SEC-3 must allow pg-restore to reach the object store in pg-ha.

## Not verified yet
That Patroni keeps the restore settings with keep_existing_recovery_conf, that the restored leader promotes by itself,
that the replicas catch up from the leader, and that archiving stays off on every member.

## Amendment 1 (name of the RS-3 test, 2026-11-22)
Old: the test of RS-3 was tests/rs-scheduled.sh, the name from the first SPEC wording ("Scheduled restore test").
New: tests/rs-restore-test.sh. SPEC.md names it in the RS-3 entry.
Why: the human changed RS-3 to an on-demand restore test (SPEC edit in commit a3054f0) and asked to rename the file, because the
name said "scheduled" for a test that is not scheduled.
What did not change: the checks of the test. Only one comment sentence changed. docs/evidence/RS-3.txt was produced under the old
name, and the test was not rerun after the rename (its output does not print the file name).
