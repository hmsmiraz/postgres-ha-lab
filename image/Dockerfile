ARG BASE_IMAGE=postgres:18.7-trixie
FROM ${BASE_IMAGE}

ARG BASE_IMAGE
ARG PGBACKREST_APT_VERSION
ARG PATRONI_VERSION
ARG POSTGRES_VERSION

LABEL org.opencontainers.image.title="pg-ha" \
      org.opencontainers.image.description="PostgreSQL with Patroni and pgBackRest" \
      org.opencontainers.image.base.name="${BASE_IMAGE}"

# pgBackRest from the PGDG repo (already configured in the official image),
# tini as PID 1 so zombie processes are reaped, python for Patroni.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-venv tini \
      "pgbackrest=${PGBACKREST_APT_VERSION}" \
 && rm -rf /var/lib/apt/lists/*

# Patroni and its dependencies from the committed lock file, in a venv.
COPY image/requirements.lock /tmp/requirements.lock
RUN python3 -m venv /opt/patroni \
 && /opt/patroni/bin/pip install --no-cache-dir --require-virtualenv -r /tmp/requirements.lock \
 && rm /tmp/requirements.lock

ENV PATH="/opt/patroni/bin:${PATH}"

RUN mkdir -p /pgdata /etc/patroni \
 && chown postgres:postgres /pgdata \
 && chmod 700 /pgdata

USER postgres
WORKDIR /home/postgres

# Patroni starts and stops Postgres itself, so we do not use the stock entrypoint.
ENTRYPOINT ["tini", "--", "patroni"]
CMD ["/etc/patroni/patroni.yml"]
