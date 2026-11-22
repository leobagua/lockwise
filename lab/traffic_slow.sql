-- Read, write, read on the hot tables with 1000 to 3000 ms of application think time.
\set id random(1, 100000)
\set pause random(1000, 3000)
BEGIN;
SELECT pad FROM child WHERE id = :id;
\sleep :pause ms
UPDATE child SET pad = pad WHERE id = :id;
SELECT pad FROM parent WHERE id = :id;
END;
