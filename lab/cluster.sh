#!/usr/bin/env bash
# Starts or stops the lab cluster. Usage: lab/cluster.sh start|stop   VER=17.8
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
VER=${VER:-17.8}
BIN=${PG_ROOT:-$HOME/.local/share/mise/installs/postgres}/$VER/bin
RUN=$HERE/.run/$VER

case ${1:-} in
start)
  rm -rf "$RUN"
  mkdir -p "$RUN"
  "$BIN/initdb" -D "$RUN/data" -U postgres -A trust >/dev/null || exit 1
  cat >>"$RUN/data/postgresql.conf" <<CONF
listen_addresses = ''
unix_socket_directories = '$RUN'
max_connections = 300
shared_buffers = 512MB
fsync = off
synchronous_commit = off
deadlock_timeout = 5s
autovacuum_naptime = 1s
log_autovacuum_min_duration = 0
log_lock_waits = on
CONF
  "$BIN/pg_ctl" -D "$RUN/data" -l "$RUN/server.log" -w start >/dev/null || exit 1
  "$BIN/psql" -X -q -h "$RUN" -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE mig LOGIN;
GRANT pg_monitor TO mig;
CREATE ROLE app LOGIN;
ALTER ROLE app SET statement_timeout = '15s';
ALTER ROLE app SET idle_in_transaction_session_timeout = '30s';
CREATE DATABASE lab OWNER mig;
\connect lab mig
CREATE TABLE parent (id int PRIMARY KEY, pad text) WITH (autovacuum_enabled = false);
CREATE TABLE child (id int PRIMARY KEY, parent_id int, pad text) WITH (autovacuum_enabled = false);
INSERT INTO parent SELECT g, repeat('x', 100) FROM generate_series(-9, 100000) g;
INSERT INTO child SELECT g, g, repeat('x', 100) FROM generate_series(-9, 100000) g;
GRANT ALL ON parent, child TO app;
VACUUM ANALYZE parent, child;
SQL
  ;;
stop)
  "$BIN/pg_ctl" -D "$RUN/data" -m immediate stop >/dev/null
  ;;
*)
  echo "usage: lab/cluster.sh start|stop" >&2
  exit 1
  ;;
esac
