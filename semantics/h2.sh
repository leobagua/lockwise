# H2: a pending SHARE UPDATE EXCLUSIVE request neither blocks DML nor takes
# weak locks off the fast path. Controls: a pending SHARE ROW EXCLUSIVE and a
# pending ACCESS EXCLUSIVE do.

mig "CREATE TABLE h2 (id int) WITH (autovacuum_enabled = false)"

# Holds SHARE UPDATE EXCLUSIVE for 4s, then a second session queues <mode>.
queue_behind_holder() {
  local mode=$1
  session h2_holder <<'SQL'
BEGIN;
LOCK TABLE h2 IN SHARE UPDATE EXCLUSIVE MODE;
\! sleep 4
COMMIT;
SQL
  sleep 0.5
  session h2_waiter <<SQL
BEGIN;
LOCK TABLE h2 IN $mode MODE;
COMMIT;
SQL
  wait_for "$(waiting_on_lock h2_waiter)" 5
}

probe() {
  mig "BEGIN; SET LOCAL statement_timeout = '1s'; $1;
       SELECT fastpath FROM pg_locks WHERE pid = pg_backend_pid() AND relation = 'h2'::regclass AND mode = '$2';
       COMMIT" | tr '\n' ' '
}

queue_behind_holder "SHARE UPDATE EXCLUSIVE"
insert_result=$(probe "INSERT INTO h2 VALUES (1)" RowExclusiveLock)
wait
if [[ "$insert_result" == "t "* ]]; then
  report H2 PASSOU "INSERT passa com pré-lock pendente e fica no fast-path"
else
  report H2 REFUTADA "saída: $insert_result"
fi

queue_behind_holder "SHARE ROW EXCLUSIVE"
select_result=$(probe "SELECT count(*) FROM h2" AccessShareLock)
insert_result=$(probe "INSERT INTO h2 VALUES (2)" RowExclusiveLock)
wait
if [[ "$select_result" == *"f "* && "$insert_result" == *"statement timeout"* ]]; then
  report H2-controle-SRE PASSOU "SELECT passa fora do fast-path, INSERT fica represado"
else
  report H2-controle-SRE REFUTADA "select: $select_result insert: $insert_result"
fi

queue_behind_holder "ACCESS EXCLUSIVE"
select_result=$(probe "SELECT count(*) FROM h2" AccessShareLock)
wait
if [[ "$select_result" == *"statement timeout"* ]]; then
  report H2-controle-AEL PASSOU "SELECT novo fica represado"
else
  report H2-controle-AEL REFUTADA "select: $select_result"
fi

mig "DROP TABLE h2"
