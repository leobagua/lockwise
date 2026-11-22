# Helpers shared by the hypothesis scripts. Expects BIN, RUN, VER and RESULTS.

PSQL=("$BIN/psql" -X -A -t -q -h "$RUN" -d lab)

# Superuser, used only to observe.
su() { "${PSQL[@]}" -U postgres -c "$1" 2>&1; }

# Non-superuser table owner, the role every tested behaviour runs as.
mig() { "${PSQL[@]}" -U mig -c "$1" 2>&1; }

# Background session as mig. Reads the script from stdin, tags the backend
# with application_name=<name> and writes its output to out/<name>.out.
session() {
  local name=$1
  cat >"$RUN/out/$name.sql"
  PGAPPNAME=$name "${PSQL[@]}" -U mig -f "$RUN/out/$name.sql" >"$RUN/out/$name.out" 2>&1 &
}

out() { cat "$RUN/out/$1.out"; }

# Polls a boolean query until it returns t.
wait_for() {
  local sql=$1 seconds=${2:-10} attempt
  for ((attempt = 0; attempt < seconds * 10; attempt++)); do
    [ "$(su "$sql")" = t ] && return 0
    sleep 0.1
  done
  return 1
}

waiting_on_lock() {
  echo "SELECT count(*) = 1 FROM pg_stat_activity WHERE application_name = '$1' AND wait_event_type = 'Lock'"
}

log_count() { grep -c "$1" "$RUN/server.log"; }

between() { awk -v value="$1" -v low="$2" -v high="$3" 'BEGIN { exit !(value >= low && value <= high) }'; }

report() { printf '%s\t%s\t%s\t%s\n' "$VER" "$1" "$2" "$3" | tee -a "$RESULTS"; }
