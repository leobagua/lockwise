#!/usr/bin/env bash
# Starts a throwaway Postgres and runs the end-to-end tests against it.
# Usage: tests/run.sh   VER=17.8 PG_ROOT=<dir with <version>/bin>
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
VER=${VER:-17.8}
BIN=${PG_ROOT:-$HOME/.local/share/mise/installs/postgres}/$VER/bin
RUN=$HERE/.run

"$BIN/pg_ctl" -D "$RUN/data" -m immediate stop >/dev/null 2>&1 || true
rm -rf "$RUN"
mkdir -p "$RUN"
trap '"$BIN/pg_ctl" -D "$RUN/data" -m immediate stop >/dev/null 2>&1' EXIT

"$BIN/initdb" -D "$RUN/data" -U postgres -A trust >/dev/null
cat >>"$RUN/data/postgresql.conf" <<CONF
listen_addresses = ''
unix_socket_directories = '$RUN'
fsync = off
CONF
"$BIN/pg_ctl" -D "$RUN/data" -l "$RUN/server.log" -w start >/dev/null
"$BIN/psql" -X -q -h "$RUN" -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "CREATE ROLE mig LOGIN" -c "GRANT pg_monitor TO mig" -c "CREATE DATABASE lab OWNER mig"

cd "$HERE/.."
LOCKWISE_TEST_CONN="host=$RUN user=mig dbname=lab" cargo test --test end_to_end -- --test-threads=1
