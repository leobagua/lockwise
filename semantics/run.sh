#!/usr/bin/env bash
# Runs every hypothesis in semantics/h*.sh against throwaway Postgres clusters.
# Usage: semantics/run.sh [h1 h3 ...]   VERSIONS="17.8 18.4" PG_ROOT=<dir with <version>/bin>
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
VERSIONS=${VERSIONS:-"17.8 18.4"}
PG_ROOT=${PG_ROOT:-$HOME/.local/share/mise/installs/postgres}
ONLY=("$@")
export RESULTS=$HERE/.run/results.tsv

mkdir -p "$HERE/.run"
: >"$RESULTS"

stop_cluster() {
  [ -n "${BIN:-}" ] && "$BIN/pg_ctl" -D "$RUN/data" -m immediate stop >/dev/null 2>&1
}
trap stop_cluster EXIT

selected() {
  [ ${#ONLY[@]} -eq 0 ] && return 0
  local name
  for name in "${ONLY[@]}"; do [ "$name" = "$1" ] && return 0; done
  return 1
}

for VER in $VERSIONS; do
  export VER BIN=$PG_ROOT/$VER/bin RUN=$HERE/.run/$VER
  rm -rf "$RUN"
  mkdir -p "$RUN/out"

  "$BIN/initdb" -D "$RUN/data" -U postgres -A trust >/dev/null || exit 1
  cat >>"$RUN/data/postgresql.conf" <<CONF
listen_addresses = ''
unix_socket_directories = '$RUN'
fsync = off
synchronous_commit = off
deadlock_timeout = 1s
autovacuum_naptime = 1s
log_autovacuum_min_duration = 0
log_lock_waits = on
CONF
  "$BIN/pg_ctl" -D "$RUN/data" -l "$RUN/server.log" -w start >/dev/null || exit 1
  "$BIN/psql" -X -q -h "$RUN" -U postgres -d postgres \
    -c "CREATE ROLE mig LOGIN" -c "CREATE DATABASE lab OWNER mig" || exit 1

  for test_file in "$HERE"/h*.sh; do
    test_name=$(basename "$test_file" .sh)
    selected "$test_name" || continue
    echo "== PG $VER $test_name"
    (source "$HERE/lib.sh"; source "$test_file"; wait)
  done

  stop_cluster
done

echo
column -t -s $'\t' "$RESULTS"
