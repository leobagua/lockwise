use crate::preset::{Kill, Preset, Random, Watcher};
use postgres::error::SqlState;
use postgres::{Client, NoTls};
use serde_json::json;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub struct LockRequest {
    pub table: String,
    pub mode: &'static str,
}

impl LockRequest {
    pub fn parse(spec: &str) -> Result<LockRequest, String> {
        let (table, mode) = spec.split_once(':').ok_or(format!("--lock expects table:mode, got {spec}"))?;
        let mode = match mode {
            "ael" => "ACCESS EXCLUSIVE",
            "sre" => "SHARE ROW EXCLUSIVE",
            "sue" => "SHARE UPDATE EXCLUSIVE",
            other => return Err(format!("unknown lock mode {other}, use ael, sre or sue")),
        };
        Ok(LockRequest { table: table.to_string(), mode })
    }
}

pub struct Job<'a> {
    pub connection: &'a str,
    pub preset: &'a Preset,
    pub locks: &'a [LockRequest],
    pub sql: Option<&'a str>,
}

enum AttemptEnd {
    Done { waited: Duration, held: Duration },
    Retry { waited: Duration, cause: String },
}

struct WatcherState {
    armed: AtomicBool,
    stop: AtomicBool,
    verdict: Mutex<Option<String>>,
}

pub fn emit(event: &str, fields: serde_json::Value) {
    let seconds = SystemTime::now().duration_since(UNIX_EPOCH).map(|elapsed| elapsed.as_secs_f64()).unwrap_or(0.0);
    let mut line = json!({ "at": seconds, "event": event });
    line.as_object_mut().unwrap().extend(fields.as_object().cloned().unwrap_or_default());
    println!("{line}");
}

pub fn run(job: &Job) -> Result<bool, postgres::Error> {
    let started = Instant::now();
    let deadline = started + Duration::from_secs(job.preset.max_runtime_s);
    let mut client = Client::connect(job.connection, NoTls)?;
    let backend_pid: i32 = client.query_one("SELECT pg_backend_pid()", &[])?.get(0);
    let table_oids = table_oids(&mut client, job.locks)?;

    let watcher_state = Arc::new(WatcherState {
        armed: AtomicBool::new(false),
        stop: AtomicBool::new(false),
        verdict: Mutex::new(None),
    });
    let watcher_thread = job.preset.watcher.clone().map(|settings| {
        let state = Arc::clone(&watcher_state);
        let connection = job.connection.to_string();
        let oids = table_oids.clone();
        thread::spawn(move || watch(&connection, &settings, backend_pid, &oids, &state))
    });

    emit("queued", json!({ "preset": job.preset.name, "pid": backend_pid }));

    let attempts = job.preset.attempts(&mut Random::seeded_from_clock());
    let mut total_waited = Duration::ZERO;
    let mut outcome = None;
    let mut attempts_made = 0;

    for (index, attempt) in attempts.iter().enumerate() {
        if Instant::now() >= deadline {
            break;
        }
        attempts_made = index + 1;
        watcher_state.verdict.lock().unwrap().take();
        watcher_state.armed.store(true, Ordering::SeqCst);
        let end = try_once(&mut client, job, attempt.lock_timeout);
        watcher_state.armed.store(false, Ordering::SeqCst);

        match end? {
            AttemptEnd::Done { waited, held } => {
                total_waited += waited;
                outcome = Some(held);
                break;
            }
            AttemptEnd::Retry { waited, cause } => {
                total_waited += waited;
                let cause = watcher_state.verdict.lock().unwrap().take().unwrap_or(cause);
                emit(
                    "waiting",
                    json!({ "attempt": attempts_made, "cause": cause,
                            "lock_timeout_ms": attempt.lock_timeout.as_millis() as u64,
                            "waited_ms": waited.as_millis() as u64 }),
                );
                if job.preset.kill == Kill::All {
                    terminate_lock_holders(&mut client, &table_oids)?;
                } else {
                    thread::sleep(attempt.sleep_after.min(deadline.saturating_duration_since(Instant::now())));
                }
            }
        }
    }

    watcher_state.stop.store(true, Ordering::SeqCst);
    if let Some(handle) = watcher_thread {
        let _ = handle.join();
    }

    emit(
        "result",
        json!({ "outcome": if outcome.is_some() { "success" } else { "gave_up" },
                "attempts": attempts_made,
                "total_ms": started.elapsed().as_millis() as u64,
                "waited_in_queue_ms": total_waited.as_millis() as u64,
                "held_ms": outcome.map(|held| held.as_millis() as u64) }),
    );
    Ok(outcome.is_some())
}

pub fn table_oids(client: &mut Client, locks: &[LockRequest]) -> Result<Vec<u32>, postgres::Error> {
    locks
        .iter()
        .map(|lock| Ok(client.query_one("SELECT $1::text::regclass::oid", &[&lock.table])?.get(0)))
        .collect()
}

fn try_once(client: &mut Client, job: &Job, lock_timeout: Duration) -> Result<AttemptEnd, postgres::Error> {
    let attempt_started = Instant::now();
    let mut transaction = client.transaction()?;
    let locked = (|| {
        transaction.batch_execute(&format!("SET LOCAL lock_timeout = '{}ms'", lock_timeout.as_millis()))?;
        for lock in job.locks {
            transaction.batch_execute(&format!("LOCK TABLE {} IN {} MODE", lock.table, lock.mode))?;
        }
        Ok(())
    })();
    let waited = attempt_started.elapsed();

    if let Err(error) = locked {
        return match retryable_cause(&error) {
            Some(cause) => Ok(AttemptEnd::Retry { waited, cause }),
            None => Err(error),
        };
    }

    let acquired_at = Instant::now();
    emit("acquired", json!({ "waited_ms": waited.as_millis() as u64 }));
    if let Some(sql) = job.sql {
        transaction.batch_execute(sql)?;
    }
    transaction.commit()?;
    Ok(AttemptEnd::Done { waited, held: acquired_at.elapsed() })
}

pub fn retryable_cause(error: &postgres::Error) -> Option<String> {
    let code = error.code()?;
    if *code == SqlState::LOCK_NOT_AVAILABLE {
        Some("lock_timeout".to_string())
    } else if *code == SqlState::QUERY_CANCELED {
        Some("canceled".to_string())
    } else if *code == SqlState::T_R_DEADLOCK_DETECTED {
        Some("deadlock".to_string())
    } else {
        None
    }
}

fn terminate_lock_holders(client: &mut Client, table_oids: &[u32]) -> Result<(), postgres::Error> {
    let terminated: i64 = client
        .query_one(
            "SELECT count(pg_terminate_backend(pid)) FROM (
               SELECT DISTINCT pid FROM pg_locks
                WHERE locktype = 'relation' AND relation = ANY($1) AND granted AND pid <> pg_backend_pid()
             ) AS holders",
            &[&table_oids],
        )?
        .get(0);
    emit("killed", json!({ "backends": terminated }));
    Ok(())
}

/// Bills blocked-backend-seconds for the queue behind the DDL and cancels the
/// DDL's own wait when the bill or the queue depth goes over budget.
fn watch(connection: &str, settings: &Watcher, ddl_pid: i32, table_oids: &[u32], state: &WatcherState) {
    let Ok(mut client) = Client::connect(connection, NoTls) else { return };
    let poll = Duration::from_millis(settings.poll_ms);
    let mut bill = 0.0;

    while !state.stop.load(Ordering::SeqCst) {
        thread::sleep(poll);
        if !state.armed.load(Ordering::SeqCst) {
            bill = 0.0;
            continue;
        }
        let Ok(row) = client.query_one(
            "SELECT count(*) FROM pg_locks
              WHERE locktype = 'relation' AND relation = ANY($1) AND NOT granted AND pid <> $2",
            &[&table_oids, &ddl_pid],
        ) else {
            continue;
        };
        let queued: i64 = row.get(0);
        bill += queued as f64 * poll.as_secs_f64();

        let verdict = if queued >= settings.queue_cap {
            Some("queue_cap")
        } else if bill > settings.budget_blocked_seconds {
            Some("damage_budget")
        } else {
            None
        };
        if let Some(verdict) = verdict {
            *state.verdict.lock().unwrap() = Some(verdict.to_string());
            let _ = client.execute(
                "SELECT pg_cancel_backend(pid) FROM pg_stat_activity
                  WHERE pid = $1 AND state = 'active' AND wait_event_type = 'Lock'",
                &[&ddl_pid],
            );
            bill = 0.0;
        }
    }
}
