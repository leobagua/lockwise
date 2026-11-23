#!/usr/bin/env bash
# Runs one blocker scenario against one preset and appends a line per repetition
# to lab/.run/results.tsv.
# Usage: lab/run.sh <fast|long15x1|long15x3|autovac> <preset name> [repetitions]
#        VER=17.8 RATE=500 CLIENTS=100 TABLES="child"
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
SCENARIO=$1
PRESET=$2
REPETITIONS=${3:-5}
VER=${VER:-17.8}
RATE=${RATE:-500}
CLIENTS=${CLIENTS:-100}
TABLES=${TABLES:-child}
WARMUP=5
BIN=${PG_ROOT:-$HOME/.local/share/mise/installs/postgres}/$VER/bin
RUN=$HERE/.run/$VER
RESULTS=$HERE/.run/results.tsv
PRESET_FILE=$ROOT/rust/presets/$PRESET.toml
MAX_RUNTIME=$(awk -F' *= *' '$1 == "max_runtime_s" { print $2 }' "$PRESET_FILE")
PSQL=("$BIN/psql" -X -A -t -q -h "$RUN" -d lab)

# The kill-all reference needs to signal autovacuum workers, so it runs as superuser.
DDL_USER=mig
[[ "$PRESET" == s3-* ]] && DDL_USER=postgres

now() { "${PSQL[@]}" -U postgres -c "SELECT extract(epoch FROM clock_timestamp())"; }

# Holds a row lock on child for 14s, over and over. Each loop uses its own row.
long_transaction_loop() {
  local row=$1 gap=$2
  while true; do
    PGAPPNAME=blocker "${PSQL[@]}" -U app \
      -c "BEGIN; UPDATE child SET pad = pad WHERE id = $row; SELECT pg_sleep(14); COMMIT" >/dev/null 2>&1
    sleep "$gap"
  done
}

start_blockers() {
  BLOCKER_LOOPS=()
  case $SCENARIO in
  fast) ;;
  long15x1)
    long_transaction_loop 0 2 &
    BLOCKER_LOOPS+=($!)
    ;;
  long15x3)
    for row in 0 -1 -2; do
      long_transaction_loop "$row" 0 &
      BLOCKER_LOOPS+=($!)
      sleep 4.7
    done
    ;;
  autovac)
    "${PSQL[@]}" -U mig -c "ALTER TABLE child SET (autovacuum_enabled = true,
      autovacuum_vacuum_threshold = 0, autovacuum_vacuum_scale_factor = 0,
      autovacuum_vacuum_insert_threshold = -1, autovacuum_analyze_threshold = 2000000000,
      autovacuum_vacuum_cost_delay = 100, autovacuum_vacuum_cost_limit = 1)"
    ;;
  *)
    echo "unknown scenario $SCENARIO" >&2
    exit 1
    ;;
  esac
}

stop_blockers() {
  [ ${#BLOCKER_LOOPS[@]} -gt 0 ] && kill "${BLOCKER_LOOPS[@]}" 2>/dev/null
  "${PSQL[@]}" -U postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'blocker'" >/dev/null
  if [ "$SCENARIO" = autovac ]; then
    "${PSQL[@]}" -U mig -c "ALTER TABLE child SET (autovacuum_enabled = false)"
  fi
}

# Traffic mix: 95% of transactions think for up to 20 ms, 4.5% up to 500 ms and
# 0.5% up to 3 s, so some transaction is almost always in flight on the table.
TRAFFIC=(-f "$HERE/traffic_fast.sql@950" -f "$HERE/traffic_mid.sql@45" -f "$HERE/traffic_slow.sql@5")

# Latency beyond what each script can take by design (think time plus 20 ms),
# summed over the transactions that ran while the strategy was working.
# Prints "<damage seconds> <worst excess ms>".
damage() {
  cat "$3"/pgbench.* | awk -v started="$1" -v finished="$2" '
    BEGIN { allowed[0] = 0.04; allowed[1] = 0.52; allowed[2] = 3.02 }
    { at = $5 + $6 / 1e6; excess = ($3 + $7) / 1e6 - allowed[$4] }
    at >= started && at <= finished + 2 && excess > 0 {
      total += excess
      if (excess > worst) worst = excess
    }
    END { printf "%.2f %.0f", total, worst * 1000 }'
}

field() { grep '"event":"result"' "$1" | sed -E "s/.*\"$2\":\"?([^,\"}]+).*/\1/"; }

for repetition in $(seq 1 "$REPETITIONS"); do
  out=$HERE/.run/results/$SCENARIO/$PRESET/$repetition
  rm -rf "$out"
  mkdir -p "$out"

  (cd "$out" && exec "$BIN/pgbench" -n -h "$RUN" -U app "${TRAFFIC[@]}" -c "$CLIENTS" -j 4 \
    -R "$RATE" -T $((WARMUP + MAX_RUNTIME + 60)) -l --log-prefix=pgbench lab >/dev/null 2>pgbench.err) &
  traffic=$!
  sleep "$WARMUP"
  if ! kill -0 "$traffic" 2>/dev/null; then
    cat "$out/pgbench.err" >&2
    exit 1
  fi

  start_blockers
  sleep 1

  PGAPPNAME=sampler "${PSQL[@]}" -U postgres >"$out/sampler.tsv" 2>/dev/null <<'SQL' &
SELECT extract(epoch FROM clock_timestamp()),
       count(*) FILTER (WHERE wait_event_type = 'Lock'),
       count(*) FILTER (WHERE wait_event = 'LockManager')
  FROM pg_stat_activity
 WHERE usename = 'app' AND state = 'active' \watch 0.2
SQL
  sampler=$!

  started=$(now)
  # The lab measures lock acquisition alone, so every preset but the control
  # takes ACCESS EXCLUSIVE explicitly and runs no SQL.
  lock_flags=()
  for table in $TABLES; do lock_flags+=(--table "$table"); done
  [ "$PRESET" = control ] || lock_flags+=(--access-exclusive)
  "${LOCKWISE:-$ROOT/rust/target/release/lockwise}" run --conn "host=$RUN user=$DDL_USER dbname=lab" \
    --preset "$PRESET_FILE" "${lock_flags[@]}" >"$out/events.jsonl" 2>"$out/lockwise.err"
  finished=$(now)

  sleep 2
  stop_blockers
  kill "$sampler" 2>/dev/null
  wait "$sampler" 2>/dev/null
  kill -ALRM "$traffic" 2>/dev/null
  wait "$traffic" 2>/dev/null

  read -r damage_seconds worst_latency_ms <<<"$(damage "$started" "$finished" "$out")"
  read -r blocked_backend_seconds deepest_queue <<<"$(awk -F'|' -v started="$started" '
    $1 >= started { total += $2 * 0.2; if ($2 > deepest) deepest = $2 }
    END { printf "%.1f %d", total, deepest }' "$out/sampler.tsv")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$VER" "$SCENARIO" "$PRESET" "$repetition" \
    "$(field "$out/events.jsonl" outcome)" "$(field "$out/events.jsonl" attempts)" \
    "$(field "$out/events.jsonl" total_ms)" "$damage_seconds" "$worst_latency_ms" \
    "$blocked_backend_seconds" "$deepest_queue" | tee -a "$RESULTS"
done
