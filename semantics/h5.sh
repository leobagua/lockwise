# H5: DDLs that take the pre-lock on the same table are served in arrival order.

mig "CREATE TABLE h5 (id int) WITH (autovacuum_enabled = false)"

session h5_first <<'SQL'
BEGIN;
LOCK TABLE h5 IN SHARE UPDATE EXCLUSIVE MODE;
\! sleep 2
COMMIT;
SQL
sleep 0.3

session h5_second <<'SQL'
BEGIN;
LOCK TABLE h5 IN SHARE UPDATE EXCLUSIVE MODE;
SELECT extract(epoch FROM clock_timestamp());
\! sleep 1
COMMIT;
SQL
sleep 0.3

session h5_third <<'SQL'
BEGIN;
LOCK TABLE h5 IN SHARE UPDATE EXCLUSIVE MODE;
SELECT extract(epoch FROM clock_timestamp());
COMMIT;
SQL
wait

second_at=$(out h5_second | tail -1)
third_at=$(out h5_third | tail -1)
gap=$(awk -v second="$second_at" -v third="$third_at" 'BEGIN { printf "%.2f", third - second }')

if between "$gap" 0.9 2; then
  report H5 PASSOU "a terceira DDL foi atendida ${gap}s depois da segunda"
else
  report H5 REFUTADA "segunda: $second_at terceira: $third_at"
fi

mig "DROP TABLE h5"
