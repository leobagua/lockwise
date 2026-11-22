-- Read, write, read on the hot tables with 100 to 500 ms of application think time.
\set id random(1, 100000)
\set pause random(100, 500)
BEGIN;
SELECT pad FROM child WHERE id = :id;
\sleep :pause ms
UPDATE child SET pad = pad WHERE id = :id;
SELECT pad FROM parent WHERE id = :id;
END;
