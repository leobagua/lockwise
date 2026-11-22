# lockwise

Runs a DDL on a hot Postgres table and pauses the table only once, for a time you choose.

It is a single binary that talks plain SQL to the server.

> Current state: prototype.

## The problem

DDL locks on busy tables can lead to lock contention.

A DDL such as `ALTER TABLE` needs a strong lock. While it waits for that lock, every new query on the table queues behind it. On a busy table the queue grows fast, connections pile up and the application slows down or fails.

The usual answer is to ask for the lock with a short timeout and retry. Each request still stops the table for a moment. After hundreds of requests the migration gives up without running, and the contention happened anyway.

## How lockwise solves it

It does three things, in this order.

1. **Waits without getting in the way.** It first takes a weak lock, `SHARE UPDATE EXCLUSIVE`. This lock does not block reads or writes. It moves autovacuum out of the way and puts DDLs in a queue.
2. **Looks before it asks.** It checks who is using the table and for how long. If there is a long transaction, it waits for it to end. The table keeps working.
3. **Asks for the strong lock once, with a deadline.** If it gets the lock, it runs the DDL and releases. If a gap never shows up, it does not ask, and it tells you who is blocking.

## Usage

```bash
cargo build --release

target/release/lockwise run \
  --conn "host=localhost user=migrator dbname=app" \
  --preset presets/c1-window-3000ms.toml \
  --lock accounts:ael \
  --sql "ALTER TABLE accounts ADD COLUMN note text"
```

`--lock` takes the table and the mode. The modes are `ael` for `ACCESS EXCLUSIVE` and `sre` for `SHARE ROW EXCLUSIVE`.

The database user needs the `pg_monitor` role. Use a direct connection to Postgres.

## Configuration

The preset is a TOML file.

```toml
name = "c1-window-3000ms"
max_runtime_s = 120      # total time before giving up

[window]
max_pause_ms = 3000      # the longest the table may be paused
cooldown_ms = 10000      # time between attempts
poll_ms = 200            # how often it looks at the blockers
prelock_hold_s = 60      # how long it keeps the weak lock
```

The value that matters most is `max_pause_ms`. A shorter pause does less harm and needs a larger gap in traffic.

## Output

The tool writes one JSON event per line.

| Event | Meaning |
|---|---|
| `queued` | Started. |
| `prelocked` | Got the weak lock. |
| `waiting` | Waiting. Lists who is blocking. |
| `acquired` | Got the strong lock. |
| `result` | Finished, with success or gave up. |

The exit code is `0` for success, `2` for gave up and `1` for error.

## Tests

```bash
tests/run.sh
```

The script starts a throwaway Postgres and runs the end-to-end tests. It looks for the Postgres binaries in `~/.local/share/mise/installs/postgres/17.8/bin`. Set `PG_ROOT` and `VER` to use another location.
