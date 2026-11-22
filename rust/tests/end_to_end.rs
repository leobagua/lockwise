use postgres::{Client, NoTls};
use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Output, Stdio};
use std::sync::mpsc::{channel, Sender};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const ADD_NOTE: &str = "ALTER TABLE accounts ADD COLUMN note text";
const ADD_OWNER: &str = "ALTER TABLE accounts ADD COLUMN owner text";

fn connection_string() -> String {
    std::env::var("LOCKWISE_TEST_CONN").expect("run the tests through tests/run.sh")
}

fn connect() -> Client {
    Client::connect(&connection_string(), NoTls).unwrap()
}

fn create_accounts_table() -> Client {
    let mut client = connect();
    client
        .batch_execute("DROP TABLE IF EXISTS accounts; CREATE TABLE accounts (id int PRIMARY KEY) WITH (autovacuum_enabled = false); INSERT INTO accounts VALUES (1)")
        .unwrap();
    client
}

/// Holds a row lock on accounts until the returned sender is used or dropped.
fn open_transaction_on_accounts() -> (Sender<()>, JoinHandle<()>) {
    let (release, released) = channel();
    let (locked, lock_taken) = channel();
    let handle = thread::spawn(move || {
        let mut client = connect();
        let mut transaction = client.transaction().unwrap();
        transaction.execute("UPDATE accounts SET id = id WHERE id = 1", &[]).unwrap();
        locked.send(()).unwrap();
        let _ = released.recv();
        transaction.commit().unwrap();
    });
    lock_taken.recv().unwrap();
    (release, handle)
}

fn release_after(release: Sender<()>, delay: Duration) -> JoinHandle<()> {
    thread::spawn(move || {
        thread::sleep(delay);
        release.send(()).unwrap();
    })
}

fn lockwise_command(preset: &str, table: &str, sql: &str) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_lockwise"));
    command
        .args(["run", "--conn", &connection_string(), "--preset", preset])
        .args(["--lock", &format!("{table}:ael"), "--sql", sql]);
    command
}

fn run_lockwise(preset: &str) -> Output {
    lockwise_command(preset, "accounts", ADD_NOTE).output().unwrap()
}

/// Starts the tool in the background and returns it with its event lines.
fn start_lockwise(sql: &str) -> (Child, impl Iterator<Item = Value>) {
    let mut lockwise = lockwise_command("tests/window.toml", "accounts", sql).stdout(Stdio::piped()).spawn().unwrap();
    let lines = BufReader::new(lockwise.stdout.take().unwrap()).lines();
    (lockwise, lines.map(|line| serde_json::from_str(&line.unwrap()).unwrap()))
}

fn next_event(events: &mut impl Iterator<Item = Value>, name: &str) -> Value {
    events.find(|event| event["event"] == name).unwrap_or_else(|| panic!("no {name} event"))
}

fn weak_locks_on_accounts(client: &mut Client, granted: bool) -> i64 {
    client
        .query_one(
            "SELECT count(*) FROM pg_locks
              WHERE relation = 'accounts'::regclass AND mode = 'ShareUpdateExclusiveLock' AND granted = $1",
            &[&granted],
        )
        .unwrap()
        .get(0)
}

fn events(output: &Output) -> Vec<Value> {
    String::from_utf8_lossy(&output.stdout).lines().map(|line| serde_json::from_str(line).unwrap()).collect()
}

fn names(events: &[Value]) -> Vec<&str> {
    events.iter().map(|event| event["event"].as_str().unwrap()).collect()
}

fn column_exists(client: &mut Client, table: &str, column: &str) -> bool {
    let columns: i64 = client
        .query_one(
            "SELECT count(*) FROM information_schema.columns WHERE table_name = $1 AND column_name = $2",
            &[&table, &column],
        )
        .unwrap()
        .get(0);
    columns == 1
}

#[test]
fn waits_for_an_open_transaction_then_runs_the_ddl() {
    let mut client = create_accounts_table();
    let (release, blocker) = open_transaction_on_accounts();
    // Lets the transaction grow older than max_pause_ms before the tool looks.
    thread::sleep(Duration::from_secs(1));
    let releaser = release_after(release, Duration::from_secs(1));

    let output = run_lockwise("tests/window.toml");
    releaser.join().unwrap();
    blocker.join().unwrap();

    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(names(&events(&output)), ["queued", "prelocked", "waiting", "acquired", "result"]);
    assert!(column_exists(&mut client, "accounts", "note"));
}

#[test]
fn gives_up_without_asking_for_the_strong_lock_when_the_transaction_never_ends() {
    let mut client = create_accounts_table();
    let (release, blocker) = open_transaction_on_accounts();
    thread::sleep(Duration::from_secs(1));

    let output = run_lockwise("tests/window-short.toml");
    release.send(()).unwrap();
    blocker.join().unwrap();

    let events = events(&output);
    let result = events.last().unwrap();
    assert_eq!(output.status.code(), Some(2), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(names(&events), ["queued", "prelocked", "waiting", "result"]);
    assert_eq!(result["reason"], "long_blockers");
    assert_eq!(result["attempts"], 0);
    assert!(!column_exists(&mut client, "accounts", "note"));
}

#[test]
fn retries_after_a_strong_lock_request_that_times_out() {
    let mut client = create_accounts_table();
    let (release, blocker) = open_transaction_on_accounts();
    // The transaction is younger than max_pause_ms when the tool looks, so the
    // tool asks for the strong lock, and the request times out.
    let releaser = release_after(release, Duration::from_millis(1500));

    let output = run_lockwise("tests/window.toml");
    releaser.join().unwrap();
    blocker.join().unwrap();

    let events = events(&output);
    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(
        names(&events),
        ["queued", "prelocked", "waiting", "prelocked", "waiting", "acquired", "result"]
    );
    assert_eq!(events[2]["cause"], "attempt_failed");
    assert_eq!(events[4]["cause"], "long_blockers");
    assert_eq!(events.last().unwrap()["attempts"], 2);
    assert!(column_exists(&mut client, "accounts", "note"));
}

#[test]
fn reads_and_writes_keep_running_while_the_tool_waits_on_the_weak_lock() {
    let mut client = create_accounts_table();
    let (release, blocker) = open_transaction_on_accounts();
    thread::sleep(Duration::from_secs(1));

    let (mut lockwise, mut events) = start_lockwise(ADD_NOTE);
    next_event(&mut events, "waiting");
    assert_eq!(weak_locks_on_accounts(&mut client, true), 1);

    client.batch_execute("SET lock_timeout = '200ms'; INSERT INTO accounts VALUES (2)").unwrap();
    let rows: i64 = client.query_one("SELECT count(*) FROM accounts", &[]).unwrap().get(0);
    assert_eq!(rows, 2);

    release.send(()).unwrap();
    blocker.join().unwrap();
    assert!(lockwise.wait().unwrap().success());
}

#[test]
fn two_runs_on_the_same_table_take_turns_in_order_of_arrival() {
    let mut client = create_accounts_table();
    let (release, blocker) = open_transaction_on_accounts();
    thread::sleep(Duration::from_secs(1));

    let (mut first, mut first_events) = start_lockwise(ADD_NOTE);
    next_event(&mut first_events, "waiting");
    let (mut second, mut second_events) = start_lockwise(ADD_OWNER);
    while weak_locks_on_accounts(&mut client, false) == 0 {
        thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(weak_locks_on_accounts(&mut client, true), 1);

    release.send(()).unwrap();
    blocker.join().unwrap();
    let first_acquired = next_event(&mut first_events, "acquired")["at"].as_f64().unwrap();
    let second_acquired = next_event(&mut second_events, "acquired")["at"].as_f64().unwrap();

    assert!(first.wait().unwrap().success());
    assert!(second.wait().unwrap().success());
    assert!(first_acquired < second_acquired);
    assert!(column_exists(&mut client, "accounts", "note"));
    assert!(column_exists(&mut client, "accounts", "owner"));
}

fn autovacuum_cancellations() -> usize {
    let log = std::env::var("LOCKWISE_TEST_SERVER_LOG").expect("run the tests through tests/run.sh");
    std::fs::read_to_string(log).unwrap().matches("canceling autovacuum task").count()
}

fn autovacuum_is_running_on_ledger(client: &mut Client) -> bool {
    let workers: i64 = client
        .query_one(
            "SELECT count(*) FROM pg_stat_activity
              WHERE backend_type = 'autovacuum worker' AND query LIKE 'autovacuum: VACUUM %ledger%'",
            &[],
        )
        .unwrap()
        .get(0);
    workers == 1
}

#[test]
fn the_weak_lock_moves_a_running_autovacuum_out_of_the_way() {
    let mut client = connect();
    // The cost settings make the autovacuum slow enough to still be running when the tool starts.
    client
        .batch_execute(
            "DROP TABLE IF EXISTS ledger;
             CREATE TABLE ledger (id int, pad text) WITH (
               autovacuum_vacuum_threshold = 0, autovacuum_vacuum_scale_factor = 0,
               autovacuum_vacuum_insert_threshold = -1, autovacuum_analyze_threshold = 2000000000,
               autovacuum_vacuum_cost_delay = 100, autovacuum_vacuum_cost_limit = 1);
             INSERT INTO ledger SELECT number, repeat('x', 200) FROM generate_series(1, 50000) AS number;
             DELETE FROM ledger WHERE id % 2 = 0",
        )
        .unwrap();
    while !autovacuum_is_running_on_ledger(&mut client) {
        thread::sleep(Duration::from_millis(100));
    }
    let cancellations_before = autovacuum_cancellations();

    let output = lockwise_command("tests/window.toml", "ledger", "ALTER TABLE ledger ADD COLUMN note text")
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(names(&events(&output)), ["queued", "prelocked", "acquired", "result"]);
    assert_eq!(autovacuum_cancellations(), cancellations_before + 1);
    assert!(column_exists(&mut client, "ledger", "note"));
}
