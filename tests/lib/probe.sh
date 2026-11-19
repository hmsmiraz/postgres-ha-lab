#!/usr/bin/env bash
# Shared helpers for failover tests. Source this file, do not run it.
export LC_ALL=C
NS=pg-ha
PROBE=write-probe
LIBDIR="$(dirname "${BASH_SOURCE[0]}")"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }
now_ms() { date +%s%3N; }

# Run SQL through the pg-primary service as the app user, from any pod that answers.
sql_primary() {
  local pod out
  for pod in pg-ha-0 pg-ha-1 pg-ha-2; do
    # Single quotes are intended: the variables expand inside the pod.
    # shellcheck disable=SC2016
    if out=$(kubectl -n "$NS" exec -i "$pod" -c postgres -- sh -c \
      'PGCONNECT_TIMEOUT=2 PGPASSWORD="$APP_PASSWORD" psql -h pg-primary -U app -d appdb -Atq -v ON_ERROR_STOP=1' \
      <<<"$1" 2>/dev/null); then
      echo "$out"
      return 0
    fi
  done
  return 1
}

# Patroni's view of the cluster, from any pod that answers.
cluster_json() {
  local pod
  for pod in pg-ha-0 pg-ha-1 pg-ha-2; do
    kubectl -n "$NS" exec "$pod" -c postgres -- \
      patronictl -c /etc/patroni/patroni.yml list -f json 2>/dev/null && return 0
  done
  return 1
}

cluster_table() {
  local pod
  for pod in pg-ha-0 pg-ha-1 pg-ha-2; do
    kubectl -n "$NS" exec "$pod" -c postgres -- \
      patronictl -c /etc/patroni/patroni.yml list 2>/dev/null && return 0
  done
  return 1
}

# Wait until Patroni reports 1 leader and 2 streaming replicas. $1 = timeout in seconds.
wait_healthy() {
  local deadline=$((SECONDS + $1)) state l f
  while [ "$SECONDS" -lt "$deadline" ]; do
    state=$(cluster_json || true)
    l=$(jq '[.[] | select(.Role == "Leader")] | length' <<<"$state" 2>/dev/null || true)
    f=$(jq '[.[] | select((.Role == "Replica" or .Role == "Sync Standby") and .State == "streaming")] | length' <<<"$state" 2>/dev/null || true)
    if [ "$l" = 1 ] && [ "$f" = 2 ]; then return 0; fi
    sleep 3
  done
  return 1
}

current_leader() { cluster_json | jq -r '.[] | select(.Role == "Leader") | .Member'; }

# Number of pods that currently accept writes (must never be more than 1).
writable_primaries() {
  local pod n=0 r
  for pod in pg-ha-0 pg-ha-1 pg-ha-2; do
    r=$(kubectl -n "$NS" exec "$pod" -c postgres -- psql -U postgres -Atqc "select pg_is_in_recovery()" 2>/dev/null || true)
    if [ "$r" = "f" ]; then n=$((n + 1)); fi
  done
  echo "$n"
}

start_probe() {
  local img
  # shellcheck source=/dev/null
  source "$LIBDIR/../../versions.env"
  img="${IMAGE_NAME}:${IMAGE_TAG}"
  sql_primary "create table if not exists fo_probe(id bigserial primary key, ts_ms bigint not null); truncate fo_probe;" >/dev/null \
    || fail "cannot prepare the fo_probe table"
  kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=true >/dev/null
  sed "s|__IMAGE__|${img}|g" "$LIBDIR/write-probe.yaml" | kubectl apply -f - >/dev/null
  kubectl -n "$NS" wait --for=condition=Ready "pod/$PROBE" --timeout=120s >/dev/null \
    || fail "probe pod did not become ready"
  sleep 5
}

# $1 = log file, $2 = kill timestamp (ms). Prints: oks errs max_gap_ms time_to_first_write_ms
analyze_probe() {
  local f=$1 kill=$2 oks errs max_gap first
  oks=$(grep -c '^ok ' "$f" || true)
  errs=$(grep -c '^err ' "$f" || true)
  max_gap=$(awk '$1=="ok" { if (prev) { g=$2-prev; if (g>max) max=g } prev=$2 } END { print max+0 }' "$f")
  first=$(awk -v k="$kill" '$1=="ok" && $2>k {print $2; exit}' "$f")
  echo "$oks $errs $max_gap $((first - kill))"
}

# $1 = log file. Prints how many acknowledged writes are missing from the table.
acked_missing() {
  local acked rows n
  acked=$(mktemp)
  rows=$(mktemp)
  awk '$1=="ok" {print $2}' "$1" | sort -u > "$acked"
  sql_primary "select ts_ms from fo_probe" | sort -u > "$rows"
  n=$(comm -23 "$acked" "$rows" | wc -l)
  rm -f "$acked" "$rows"
  echo "$n"
}
