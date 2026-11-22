# H1: a SHARE UPDATE EXCLUSIVE waiter cancels a regular autovacuum after
# deadlock_timeout (1s here), and a lock_timeout below it never does.

mig "CREATE TABLE h1 (id int, pad text) WITH (
  autovacuum_vacuum_threshold = 0, autovacuum_vacuum_scale_factor = 0,
  autovacuum_vacuum_insert_threshold = -1, autovacuum_analyze_threshold = 2000000000,
  autovacuum_vacuum_cost_delay = 100, autovacuum_vacuum_cost_limit = 1)"
mig "INSERT INTO h1 SELECT g, repeat('x', 200) FROM generate_series(1, 50000) g"
mig "DELETE FROM h1 WHERE id % 2 = 0"

autovacuum_running="SELECT count(*) = 1 FROM pg_stat_activity
  WHERE backend_type = 'autovacuum worker'
    AND query LIKE 'autovacuum: VACUUM %h1%' AND query NOT LIKE '%wraparound%'"

if ! wait_for "$autovacuum_running" 20; then
  report H1 ERRO "autovacuum não iniciou"
  return
fi

cancels_before=$(log_count 'canceling autovacuum task')
short_attempt=$(mig "BEGIN; SET LOCAL lock_timeout = '500ms'; LOCK TABLE h1 IN SHARE UPDATE EXCLUSIVE MODE; COMMIT")
cancels_after_short=$(log_count 'canceling autovacuum task')

if [[ "$short_attempt" == *"lock timeout"* && "$cancels_after_short" == "$cancels_before" ]]; then
  report H1-controle PASSOU "lock_timeout 500ms falha e não cancela o autovacuum"
else
  report H1-controle REFUTADA "saída: $short_attempt, cancelamentos $cancels_before -> $cancels_after_short"
fi

wait_for "$autovacuum_running" 20

session h1_long <<'SQL'
SELECT clock_timestamp() AS started \gset
BEGIN;
SET LOCAL lock_timeout = '6s';
LOCK TABLE h1 IN SHARE UPDATE EXCLUSIVE MODE;
SELECT round(extract(epoch FROM clock_timestamp() - :'started'::timestamptz)::numeric, 2);
COMMIT;
SQL
wait

elapsed=$(out h1_long | tail -1)
cancels_after_long=$(log_count 'canceling autovacuum task')

if between "$elapsed" 0.9 3 && [ "$cancels_after_long" -gt "$cancels_after_short" ]; then
  report H1 PASSOU "pré-lock concedido em ${elapsed}s, autovacuum cancelado"
else
  report H1 REFUTADA "saída: $(out h1_long | tr '\n' ' '), cancelamentos $cancels_after_short -> $cancels_after_long"
fi

mig "DROP TABLE h1"
