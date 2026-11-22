# H3: while the pre-lock is held, a regular autovacuum skips the table. An
# anti-wraparound autovacuum queues behind it without blocking DML, and the
# holder can still upgrade to ACCESS EXCLUSIVE past that queued vacuum.

mig "CREATE TABLE h3 (id int) WITH (
  autovacuum_vacuum_threshold = 0, autovacuum_vacuum_scale_factor = 0,
  autovacuum_vacuum_insert_threshold = -1, autovacuum_analyze_threshold = 2000000000)"

session h3_holder <<'SQL'
BEGIN;
LOCK TABLE h3 IN SHARE UPDATE EXCLUSIVE MODE;
\! sleep 5
COMMIT;
SQL
sleep 0.5
mig "INSERT INTO h3 SELECT generate_series(1, 1000)"
mig "DELETE FROM h3"
wait

skips=$(log_count 'skipping vacuum of "h3"')
if [ "$skips" -gt 0 ]; then
  report H3-comum PASSOU "autovacuum comum pulou a tabela $skips vezes"
else
  report H3-comum REFUTADA "nenhum skip no log"
fi
mig "DROP TABLE h3"

mig "CREATE TABLE h3w (id int) WITH (autovacuum_freeze_max_age = 100000)"
mig "INSERT INTO h3w SELECT generate_series(1, 1000)"
mig "CREATE PROCEDURE burn_xids(amount int) LANGUAGE plpgsql AS \$\$
BEGIN
  FOR step IN 1..amount LOOP
    PERFORM pg_current_xact_id();
    COMMIT;
  END LOOP;
END \$\$"

session h3w_holder <<'SQL'
\set ON_ERROR_STOP 1
BEGIN;
LOCK TABLE h3w IN SHARE UPDATE EXCLUSIVE MODE;
\! sleep 25
SET LOCAL lock_timeout = '2s';
LOCK TABLE h3w IN ACCESS EXCLUSIVE MODE;
SELECT 'upgraded';
COMMIT;
SQL
sleep 0.5
mig "CALL burn_xids(110000)"

wraparound_waiting="SELECT count(*) = 1 FROM pg_stat_activity
  WHERE backend_type = 'autovacuum worker' AND wait_event_type = 'Lock'
    AND query LIKE 'autovacuum: VACUUM %h3w% (to prevent wraparound)'"

if wait_for "$wraparound_waiting" 15; then
  dml=$(mig "BEGIN; SET LOCAL statement_timeout = '1s'; INSERT INTO h3w VALUES (0); SELECT count(*) > 0 FROM h3w; COMMIT")
  if [ "$dml" = t ]; then
    report H3-wraparound PASSOU "anti-wraparound espera na fila e DML segue"
  else
    report H3-wraparound REFUTADA "DML: $dml"
  fi
else
  report H3-wraparound ERRO "anti-wraparound não ficou esperando o lock"
fi

wait
if [ "$(out h3w_holder | tail -1)" = upgraded ]; then
  report H3-upgrade PASSOU "upgrade para ACCESS EXCLUSIVE passa na frente do anti-wraparound"
else
  report H3-upgrade REFUTADA "saída: $(out h3w_holder | tr '\n' ' ')"
fi

mig "DROP TABLE h3w"
mig "DROP PROCEDURE burn_xids"
