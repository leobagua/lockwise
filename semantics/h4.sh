# H4: what a transaction holding the pre-lock costs the rest of the database.
# Before any strong attempt it should have no xid and no xmin. After a failed
# strong attempt inside a savepoint the pre-lock must survive, and we observe
# whether the attempt left an xid assigned, per strong mode.

mig "CREATE TABLE h4 (id int) WITH (autovacuum_enabled = false)"

session h4_idle <<'SQL'
BEGIN;
LOCK TABLE h4 IN SHARE UPDATE EXCLUSIVE MODE;
\! sleep 2
COMMIT;
SQL
sleep 1
idle_state=$(su "SELECT backend_xid IS NULL AND backend_xmin IS NULL
                   FROM pg_stat_activity
                  WHERE application_name = 'h4_idle' AND state = 'idle in transaction'")
wait

if [ "$idle_state" = t ]; then
  report H4-xmin PASSOU "transação só com pré-lock não tem xid nem xmin"
else
  report H4-xmin REFUTADA "pg_stat_activity: $idle_state"
fi

failed_attempt_in_savepoint() {
  local mode=$1
  session h4_blocker <<'SQL'
BEGIN;
INSERT INTO h4 VALUES (1);
\! sleep 2
COMMIT;
SQL
  sleep 0.5
  session h4_ddl <<SQL
BEGIN;
LOCK TABLE h4 IN SHARE UPDATE EXCLUSIVE MODE;
SAVEPOINT strong_attempt;
SET LOCAL lock_timeout = '300ms';
LOCK TABLE h4 IN $mode MODE;
ROLLBACK TO SAVEPOINT strong_attempt;
SELECT count(*) = 1 FROM pg_locks
 WHERE pid = pg_backend_pid() AND relation = 'h4'::regclass
   AND mode = 'ShareUpdateExclusiveLock' AND granted;
SELECT pg_current_xact_id_if_assigned() IS NULL;
COMMIT;
SQL
  wait
  out h4_ddl | tail -2 | tr '\n' ' '
}

for mode in "ACCESS EXCLUSIVE" "SHARE ROW EXCLUSIVE"; do
  label=H4-savepoint-$(echo "$mode" | tr -d ' ')
  read -r prelock_kept without_xid <<<"$(failed_attempt_in_savepoint "$mode")"
  if [ "$prelock_kept" != t ]; then
    report "$label" REFUTADA "pré-lock perdido, saída: $(out h4_ddl | tr '\n' ' ')"
  elif [ "$without_xid" = t ]; then
    report "$label" PASSOU "tentativa falha, pré-lock continua, sem xid"
  else
    report "$label" OBSERVADO "tentativa falha, pré-lock continua, mas a transação ganhou xid"
  fi
done

mig "DROP TABLE h4"
