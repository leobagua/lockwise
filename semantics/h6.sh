# H6: a transaction that already read the table and then writes. Does it jump
# ahead of a pending strong lock? Observed for SHARE ROW EXCLUSIVE and ACCESS EXCLUSIVE.

mig "CREATE TABLE h6 (id int) WITH (autovacuum_enabled = false)"

read_then_write_against() {
  local mode=$1
  session h6_blocker <<'SQL'
BEGIN;
INSERT INTO h6 VALUES (1);
\! sleep 4
COMMIT;
SQL
  session h6_reader <<'SQL'
BEGIN;
SELECT count(*) >= 0 FROM h6;
\! sleep 2
SET LOCAL lock_timeout = '1s';
INSERT INTO h6 VALUES (2);
SELECT 'wrote';
COMMIT;
SQL
  sleep 0.5
  session h6_ddl <<SQL
BEGIN;
LOCK TABLE h6 IN $mode MODE;
COMMIT;
SQL
  wait
  out h6_reader | tail -1
}

outcome=$(read_then_write_against "SHARE ROW EXCLUSIVE")
if [ "$outcome" = wrote ]; then
  report H6-SRE OBSERVADO "quem leu e depois escreve fura a fila"
else
  report H6-SRE OBSERVADO "quem leu e depois escreve fica represado"
fi

outcome=$(read_then_write_against "ACCESS EXCLUSIVE")
if [ "$outcome" = wrote ]; then
  report H6-AEL OBSERVADO "quem leu e depois escreve fura a fila"
else
  report H6-AEL OBSERVADO "quem leu e depois escreve fica represado"
fi

mig "DROP TABLE h6"
