//! Weak lock, look before queueing, then one bounded attempt.
//!
//! The transaction first takes SHARE UPDATE EXCLUSIVE, which waits without
//! holding traffic back. It then reads who holds locks on the tables. If any
//! holder is older than the allowed pause it waits for those transactions to
//! end. Otherwise it runs the SQL with lock_timeout equal to the allowed
//! pause, and the SQL asks for the lock it needs.

use crate::engine::{emit, lock_and_run, retryable_cause, table_oids, Job};
use crate::preset::Window;
use postgres::{Client, NoTls, Transaction};
use serde_json::json;
use std::thread;
use std::time::{Duration, Instant};

struct Holder {
    pid: i32,
    application: String,
    backend_type: String,
    age: Duration,
}

enum Cycle {
    Done { held: Duration },
    Again { cause: &'static str },
}

pub fn run(job: &Job, window: &Window) -> Result<bool, postgres::Error> {
    let started = Instant::now();
    let deadline = started + Duration::from_secs(job.preset.max_runtime_s);
    let mut ddl = Client::connect(job.connection, NoTls)?;
    let mut observer = Client::connect(job.connection, NoTls)?;
    let ddl_pid: i32 = ddl.query_one("SELECT pg_backend_pid()", &[])?.get(0);
    let oids = table_oids(&mut ddl, job.tables)?;

    emit("queued", json!({ "preset": job.preset.name, "pid": ddl_pid }));

    let mut attempts = 0;
    let mut last_cause = "deadline";
    let mut held = None;

    while Instant::now() < deadline {
        match cycle(&mut ddl, &mut observer, job, window, &oids, ddl_pid, deadline, &mut attempts)? {
            Cycle::Done { held: lock_held } => {
                held = Some(lock_held);
                break;
            }
            Cycle::Again { cause } => {
                last_cause = cause;
                thread::sleep(remaining(deadline).min(Duration::from_millis(window.cooldown_ms)));
            }
        }
    }

    emit(
        "result",
        json!({ "outcome": if held.is_some() { "success" } else { "gave_up" },
                "reason": if held.is_some() { None } else { Some(last_cause) },
                "attempts": attempts,
                "total_ms": started.elapsed().as_millis() as u64,
                "held_ms": held.map(|lock_held| lock_held.as_millis() as u64) }),
    );
    Ok(held.is_some())
}

/// One transaction: weak lock, wait for long transactions, one attempt. A
/// failed attempt ends the transaction, because a failed request for ACCESS
/// EXCLUSIVE leaves an xid behind and an open xid holds vacuum back.
#[allow(clippy::too_many_arguments)]
fn cycle(
    ddl: &mut Client,
    observer: &mut Client,
    job: &Job,
    window: &Window,
    oids: &[u32],
    ddl_pid: i32,
    deadline: Instant,
    attempts: &mut u32,
) -> Result<Cycle, postgres::Error> {
    let max_pause = Duration::from_millis(window.max_pause_ms);
    let release_weak_lock_at = Instant::now() + Duration::from_secs(window.prelock_hold_s);
    let mut transaction = ddl.transaction()?;

    let Some(statement_timeout) = take_weak_lock(&mut transaction, job.tables, oids, deadline)? else {
        return Ok(Cycle::Again { cause: "prelock_timeout" });
    };
    emit("prelocked", json!({}));

    while Instant::now() < deadline.min(release_weak_lock_at) {
        let holders = lock_holders(observer, oids, ddl_pid)?;
        let long_blockers: Vec<&Holder> = holders.iter().filter(|holder| holder.age > max_pause).collect();

        if !long_blockers.is_empty() {
            emit("waiting", json!({ "cause": "long_blockers", "blockers": describe(&long_blockers) }));
            let pids: Vec<i32> = long_blockers.iter().map(|holder| holder.pid).collect();
            wait_for_transactions_to_end(observer, &pids, window, deadline.min(release_weak_lock_at))?;
            continue;
        }

        *attempts += 1;
        transaction.batch_execute(&format!("SET LOCAL statement_timeout = '{statement_timeout}'"))?;
        let attempt_started = Instant::now();
        let waited_ms = |started: Instant| started.elapsed().as_millis() as u64;
        return match lock_and_run(&mut transaction, job, max_pause) {
            Ok(()) => {
                emit("acquired", json!({ "waited_ms": waited_ms(attempt_started) }));
                let acquired_at = Instant::now();
                transaction.commit()?;
                Ok(Cycle::Done { held: acquired_at.elapsed() })
            }
            Err(error) if retryable_cause(&error).is_some() => {
                emit("waiting", json!({ "cause": "attempt_failed", "attempt": *attempts,
                                        "waited_ms": waited_ms(attempt_started) }));
                Ok(Cycle::Again { cause: "attempt_failed" })
            }
            Err(error) => Err(error),
        };
    }

    transaction.commit()?;
    Ok(Cycle::Again { cause: "long_blockers" })
}

/// The wait for the weak lock has no time limit of its own, so the
/// statement_timeout is turned off. Returns the session value, to be given
/// back before the SQL runs, or None when the weak lock was not granted.
fn take_weak_lock(
    transaction: &mut Transaction,
    tables: &[String],
    oids: &[u32],
    deadline: Instant,
) -> Result<Option<String>, postgres::Error> {
    let mut by_oid: Vec<(&u32, &String)> = oids.iter().zip(tables).collect();
    by_oid.sort_by_key(|(oid, _)| **oid);
    let statement_timeout: String = transaction.query_one("SHOW statement_timeout", &[])?.get(0);

    transaction.batch_execute(&format!(
        "SET LOCAL statement_timeout = 0;
         SET LOCAL idle_in_transaction_session_timeout = 0;
         SET LOCAL lock_timeout = '{}ms'",
        remaining(deadline).as_millis().max(1)
    ))?;
    for (_, table) in by_oid {
        let locked = transaction.batch_execute(&format!("LOCK TABLE {table} IN SHARE UPDATE EXCLUSIVE MODE"));
        if let Err(error) = locked {
            return if retryable_cause(&error).is_some() { Ok(None) } else { Err(error) };
        }
    }
    Ok(Some(statement_timeout))
}

/// Every session with a lock on the tables. The lock the SQL will ask for is
/// unknown, so any holder may be in its way.
fn lock_holders(observer: &mut Client, oids: &[u32], ddl_pid: i32) -> Result<Vec<Holder>, postgres::Error> {
    let rows = observer.query(
        "SELECT pg_stat_activity.pid,
                pg_stat_activity.application_name,
                pg_stat_activity.backend_type,
                extract(epoch FROM clock_timestamp() - pg_stat_activity.xact_start)::float8
           FROM pg_locks
           JOIN pg_stat_activity ON pg_stat_activity.pid = pg_locks.pid
          WHERE pg_locks.locktype = 'relation'
            AND pg_locks.relation = ANY($1)
            AND pg_locks.granted
            AND pg_locks.pid <> $2
            AND pg_stat_activity.xact_start IS NOT NULL
          GROUP BY pg_stat_activity.pid, pg_stat_activity.application_name,
                   pg_stat_activity.backend_type, pg_stat_activity.xact_start",
        &[&oids, &ddl_pid],
    )?;
    Ok(rows
        .iter()
        .map(|row| Holder {
            pid: row.get(0),
            application: row.get(1),
            backend_type: row.get(2),
            age: Duration::from_secs_f64(row.get::<_, f64>(3).max(0.0)),
        })
        .collect())
}

/// Polls pg_stat_activity only, which stays off the lock manager.
fn wait_for_transactions_to_end(
    observer: &mut Client,
    pids: &[i32],
    window: &Window,
    until: Instant,
) -> Result<(), postgres::Error> {
    let snapshot_taken: std::time::SystemTime = observer.query_one("SELECT clock_timestamp()", &[])?.get(0);
    while Instant::now() < until {
        let still_open: i64 = observer
            .query_one(
                "SELECT count(*) FROM pg_stat_activity WHERE pid = ANY($1) AND xact_start < $2",
                &[&pids, &snapshot_taken],
            )?
            .get(0);
        if still_open == 0 {
            break;
        }
        thread::sleep(Duration::from_millis(window.poll_ms));
    }
    Ok(())
}

fn describe(holders: &[&Holder]) -> Vec<serde_json::Value> {
    holders
        .iter()
        .map(|holder| {
            json!({ "pid": holder.pid, "application": holder.application,
                    "backend_type": holder.backend_type, "age_ms": holder.age.as_millis() as u64 })
        })
        .collect()
}

fn remaining(deadline: Instant) -> Duration {
    deadline.saturating_duration_since(Instant::now())
}
