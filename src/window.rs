//! Pre-lock, look before queueing, then one bounded wait.
//!
//! The transaction first takes SHARE UPDATE EXCLUSIVE, which waits without
//! holding traffic back. It then reads who holds conflicting locks. If any
//! holder is older than the allowed pause it waits outside the lock queue for
//! those transactions to end. Otherwise it asks for the strong lock once, with
//! lock_timeout equal to the allowed pause.

use crate::engine::{emit, retryable_cause, table_oids, Job, LockRequest};
use crate::preset::Window;
use postgres::{Client, NoTls, Transaction};
use serde_json::json;
use std::thread;
use std::time::{Duration, Instant};

const PRELOCK_MODE: &str = "SHARE UPDATE EXCLUSIVE";

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
    let oids = table_oids(&mut ddl, job.locks)?;

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

/// One transaction: pre-lock, then strong attempts until it succeeds, the
/// pre-lock has been held long enough, or an attempt left an xid behind.
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
    let release_prelock_at = Instant::now() + Duration::from_secs(window.prelock_hold_s);
    let mut transaction = ddl.transaction()?;

    if !take_prelock(&mut transaction, job.locks, oids, deadline)? {
        return Ok(Cycle::Again { cause: "prelock_timeout" });
    }
    emit("prelocked", json!({}));

    while Instant::now() < deadline.min(release_prelock_at) {
        let holders = conflicting_holders(observer, job.locks, oids, ddl_pid)?;
        let long_blockers: Vec<&Holder> = holders.iter().filter(|holder| holder.age > max_pause).collect();

        if !long_blockers.is_empty() {
            emit("waiting", json!({ "cause": "long_blockers", "blockers": describe(&long_blockers) }));
            let pids: Vec<i32> = long_blockers.iter().map(|holder| holder.pid).collect();
            wait_for_transactions_to_end(observer, &pids, window, deadline.min(release_prelock_at))?;
            continue;
        }

        *attempts += 1;
        let attempt_started = Instant::now();
        if strong_attempt(&mut transaction, job.locks, max_pause)? {
            let acquired_at = Instant::now();
            emit("acquired", json!({ "waited_ms": attempt_started.elapsed().as_millis() as u64 }));
            if let Some(sql) = job.sql {
                transaction.batch_execute(sql)?;
            }
            transaction.commit()?;
            return Ok(Cycle::Done { held: acquired_at.elapsed() });
        }
        emit("waiting", json!({ "cause": "attempt_failed", "attempt": *attempts,
                                "waited_ms": attempt_started.elapsed().as_millis() as u64 }));

        // A failed ACCESS EXCLUSIVE request leaves an xid on the transaction, and an
        // open xid holds vacuum back, so the transaction ends here.
        if job.locks.iter().any(|lock| lock.mode == "ACCESS EXCLUSIVE") {
            transaction.commit()?;
            return Ok(Cycle::Again { cause: "attempt_failed" });
        }
        thread::sleep(remaining(deadline).min(Duration::from_millis(window.cooldown_ms)));
    }

    transaction.commit()?;
    Ok(Cycle::Again { cause: "long_blockers" })
}

fn take_prelock(
    transaction: &mut Transaction,
    locks: &[LockRequest],
    oids: &[u32],
    deadline: Instant,
) -> Result<bool, postgres::Error> {
    let mut by_oid: Vec<(&u32, &LockRequest)> = oids.iter().zip(locks).collect();
    by_oid.sort_by_key(|(oid, _)| **oid);

    transaction.batch_execute(&format!(
        "SET LOCAL statement_timeout = 0;
         SET LOCAL idle_in_transaction_session_timeout = 0;
         SET LOCAL lock_timeout = '{}ms'",
        remaining(deadline).as_millis().max(1)
    ))?;
    for (_, lock) in by_oid {
        let locked = transaction.batch_execute(&format!("LOCK TABLE {} IN {PRELOCK_MODE} MODE", lock.table));
        if let Err(error) = locked {
            return if retryable_cause(&error).is_some() { Ok(false) } else { Err(error) };
        }
    }
    Ok(true)
}

fn strong_attempt(
    transaction: &mut Transaction,
    locks: &[LockRequest],
    max_pause: Duration,
) -> Result<bool, postgres::Error> {
    let mut savepoint = transaction.savepoint("strong_attempt")?;
    let locked = (|| {
        savepoint.batch_execute(&format!("SET LOCAL lock_timeout = '{}ms'", max_pause.as_millis()))?;
        for lock in locks {
            savepoint.batch_execute(&format!("LOCK TABLE {} IN {} MODE", lock.table, lock.mode))?;
        }
        Ok(())
    })();
    match locked {
        Ok(()) => {
            savepoint.commit()?;
            Ok(true)
        }
        Err(error) if retryable_cause(&error).is_some() => {
            savepoint.rollback()?;
            Ok(false)
        }
        Err(error) => Err(error),
    }
}

fn conflicting_modes(mode: &str) -> Vec<&'static str> {
    let all = [
        "AccessShareLock",
        "RowShareLock",
        "RowExclusiveLock",
        "ShareUpdateExclusiveLock",
        "ShareLock",
        "ShareRowExclusiveLock",
        "ExclusiveLock",
        "AccessExclusiveLock",
    ];
    let first_conflict = match mode {
        "ACCESS EXCLUSIVE" => 0,
        "SHARE ROW EXCLUSIVE" => 2,
        _ => 3,
    };
    all[first_conflict..].to_vec()
}

fn conflicting_holders(
    observer: &mut Client,
    locks: &[LockRequest],
    oids: &[u32],
    ddl_pid: i32,
) -> Result<Vec<Holder>, postgres::Error> {
    let mut holders: Vec<Holder> = Vec::new();
    for (lock, oid) in locks.iter().zip(oids) {
        let rows = observer.query(
            "SELECT DISTINCT pg_stat_activity.pid,
                    pg_stat_activity.application_name,
                    pg_stat_activity.backend_type,
                    extract(epoch FROM clock_timestamp() - pg_stat_activity.xact_start)::float8
               FROM pg_locks
               JOIN pg_stat_activity ON pg_stat_activity.pid = pg_locks.pid
              WHERE pg_locks.locktype = 'relation'
                AND pg_locks.relation = $1
                AND pg_locks.granted
                AND pg_locks.mode = ANY($2)
                AND pg_locks.pid <> $3
                AND pg_stat_activity.xact_start IS NOT NULL",
            &[oid, &conflicting_modes(lock.mode), &ddl_pid],
        )?;
        for row in rows {
            let pid: i32 = row.get(0);
            if holders.iter().all(|holder| holder.pid != pid) {
                holders.push(Holder {
                    pid,
                    application: row.get(1),
                    backend_type: row.get(2),
                    age: Duration::from_secs_f64(row.get::<_, f64>(3).max(0.0)),
                });
            }
        }
    }
    Ok(holders)
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
