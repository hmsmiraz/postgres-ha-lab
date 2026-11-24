# OPS-1/2: bring-up and tear-down as code. "make down" never deletes the kind cluster.
# Images are pulled by tag on the host and loaded into kind by name:tag (see docs/known-limitations.md).
SHELL := /bin/bash
.PHONY: up down pull test-quick test

pull:
	set -a; source versions.env; set +a; \
	for i in "$${OBJSTORE_IMAGE%%@*}" "$${OBJSTORE_TLS_PROXY_IMAGE%%@*}" "$${PROMETHEUS_IMAGE%%@*}" "$${PG_EXPORTER_IMAGE%%@*}" "$${KSM_IMAGE%%@*}" "$${GRAFANA_IMAGE%%@*}"; do docker pull "$$i"; done

up: pull
	bash scripts/cluster-up.sh
	bash scripts/image-build.sh
	bash scripts/objstore-up.sh
	bash scripts/pg-up.sh
	bash scripts/obs-up.sh

down:
	bash scripts/restore-down.sh
	kubectl delete namespace pg-ha --wait=true --timeout=600s

test-quick:
	bash tests/obs-manifests.sh
	bash tests/obs-up-static.sh
	bash tests/obs-rules-static.sh
	bash tests/sec-tls-static.sh
	bash tests/sec-netpol-static.sh
	bash tests/sec-rbac.sh
	bash tests/sec-psa.sh

test: test-quick
	@echo "WARNING: the live suites below change the running cluster"
	bash tests/rep-topology.sh
	bash tests/con-endpoints.sh
	bash tests/bk-wal.sh
	bash tests/bk-verify.sh
	bash tests/rs-full.sh
	bash tests/obs-live.sh
	bash tests/obs-alerts-live.sh
