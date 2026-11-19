# AGENTS.md: playbook for any AI agent working in this repo

## Goal
Highly available PostgreSQL on Kubernetes without a Postgres operator. Patroni for HA, pgBackRest for backup and PITR, kind for the local cluster. Requirements and acceptance tests are in SPEC.md.

## Rules
1. Read SPEC.md and docs/decisions/ before changing anything.
2. Spec first: no feature code before its acceptance test exists in tests/.
3. Everything is code. No manual kubectl exec steps in the build path.
4. Pin every version in versions.env. Never use `latest`.
5. No real credentials in files, prompts or logs. Secrets are generated at `make up`.
6. No Postgres operators and no turnkey HA charts (CloudNativePG, Zalando, Crunchy, StackGres, Percona, KubeBlocks, Bitnami postgresql-ha).
7. A phase is done only when its test script passes and the output is saved under docs/evidence/.
8. Record each design choice as a short ADR in docs/decisions/.
9. Document gaps in docs/known-limitations.md. Never hide them.
10. Run shellcheck on scripts and kubeconform on manifests before committing.

## Workflow per phase
1. State the goal and the acceptance test.
2. Write the test first and see it fail.
3. Implement the smallest change that passes.
4. Run the test and save the output.
5. Update docs and the ADR. Commit.

## Conventions
- Commit messages use conventional commits (feat, fix, docs, chore, test).
- Commits are authored by the human only. No co-author or contributor trailers.
- Shell scripts: bash, `set -euo pipefail`.
- Prefer plain bash tests so any agent can run them.
