use postgres::{Client, NoTls};
use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Output, Stdio};
use std::sync::mpsc::{channel, Sender};
use std::sync::Once;
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

static FIRST_RUN: Once = Once::new();

fn create_accounts_table() -> Client {
    // The first run of a new binary is slow on macOS. Some tests need the tool
    // to start within max_pause_ms, so that run happens here.
    FIRST_RUN.call_once(|| drop(Command::new(env!("CARGO_BIN_EXE_lockwise")).output()));
    let mut client = connect();
    client
        .batch_execute("DROP TABLE IF EXISTS accounts; CREATE TABLE accounts (id int PRIMARY KEY) WITH (autovacuum_enabled = false); INSERT INTO accounts VALUES (1)")
        .unwrap();
    client
}

/// Holds a row lock on accounts until the returned sender is used or dropped.
fn open_transaction_on_accounts() -> (Sender<()>, JoinHandle<()>) {
    open_transaction("UPDATE accounts SET id = id WHERE id = 1")
}

/// Runs the statement in a transaction that stays open until the returned
/// sender is used or dropped.
fn open_transaction(statement: &'static str) -> (Sender<()>, JoinHandle<()>) {
    let (release, released) = channel();
    let (started, has_started) = channel();
    let handle = thread::spawn(move || {
        let mut client = connect();
        let mut transaction = client.transaction().unwrap();
        transaction.batch_execute(statement).unwrap();
        started.send(()).unwrap();
        let _ = released.recv();
        transaction.commit().unwrap();
    });
    has_started.recv().unwrap();
    (release, handle)
}

fn release_after(release: Sender<()>, delay: Duration) -> JoinHandle<()> {
    thread::spawn(move || {
        thread::sleep(delay);
        release.send(()).unwrap();
    })
}

fn lockwise_command(preset: &str, tables: &[&str], sql: &str) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_lockwise"));
    command.args(["run", "--conn", &connection_string(), "--preset", preset, "--sql", sql]);
    for table in tables {
        command.args(["--table", table]);
    }
    command
}

fn run_lockwise(preset: &str) -> Output {
    lockwise_command(preset, &["accounts"], ADD_NOTE).output().unwrap()
}

/// Starts the tool in the background and returns it with its event lines.
fn start_lockwise(sql: &str) -> (Child, impl Iterator<Item = Value>) {
    let mut lockwise = lockwise_command("tests/window.toml", &["accounts"], sql).stdout(Stdio::piped()).spawn().unwrap();
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

    let output = lockwise_command("tests/window.toml", &["ledger"], "ALTER TABLE ledger ADD COLUMN note text")
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(names(&events(&output)), ["queued", "prelocked", "acquired", "result"]);
    assert_eq!(autovacuum_cancellations(), cancellations_before + 1);
    assert!(column_exists(&mut client, "ledger", "note"));
}

const ADD_FOREIGN_KEY: &str = "ALTER TABLE accounts ADD FOREIGN KEY (owner_id) REFERENCES owners (id) NOT VALID";

fn create_accounts_with_owners() {
    create_accounts_table()
        .batch_execute(
            "DROP TABLE IF EXISTS owners;
             CREATE TABLE owners (id int PRIMARY KEY);
             ALTER TABLE accounts ADD COLUMN owner_id int",
        )
        .unwrap();
}

#[test]
fn the_sql_asks_for_its_own_lock_so_a_foreign_key_does_not_wait_for_a_reader() {
    create_accounts_with_owners();
    let (release, reader) = open_transaction("SELECT * FROM accounts");

    let output = lockwise_command("tests/window.toml", &["accounts"], ADD_FOREIGN_KEY).output().unwrap();
    release.send(()).unwrap();
    reader.join().unwrap();

    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(names(&events(&output)), ["queued", "prelocked", "acquired", "result"]);
}

#[test]
fn access_exclusive_is_taken_first_when_asked_for_so_the_foreign_key_waits_for_the_reader() {
    create_accounts_with_owners();
    let (release, reader) = open_transaction("SELECT * FROM accounts");
    let releaser = release_after(release, Duration::from_millis(1500));

    let output = lockwise_command("tests/window.toml", &["accounts"], ADD_FOREIGN_KEY)
        .arg("--access-exclusive")
        .output()
        .unwrap();
    releaser.join().unwrap();
    reader.join().unwrap();

    let events = events(&output);
    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(
        names(&events),
        ["queued", "prelocked", "waiting", "prelocked", "waiting", "acquired", "result"]
    );
    assert_eq!(events[2]["cause"], "attempt_failed");
}

#[test]
fn waits_for_a_long_transaction_on_any_of_the_tables() {
    create_accounts_with_owners();
    let (release, reader) = open_transaction("SELECT * FROM owners");
    thread::sleep(Duration::from_secs(1));
    let releaser = release_after(release, Duration::from_secs(1));

    let output = lockwise_command("tests/window.toml", &["owners", "accounts"], ADD_FOREIGN_KEY).output().unwrap();
    releaser.join().unwrap();
    reader.join().unwrap();

    let events = events(&output);
    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(names(&events), ["queued", "prelocked", "waiting", "acquired", "result"]);
    assert_eq!(events[2]["cause"], "long_blockers");
}

/// Each table with a lock in the given mode, and whether the lock was granted.
fn locks_in_mode(client: &mut Client, mode: &str) -> Vec<(String, bool)> {
    client
        .query(
            "SELECT relation::regclass::text, granted FROM pg_locks
              WHERE mode = $1 AND relation IS NOT NULL
              ORDER BY relation::regclass::text",
            &[&mode],
        )
        .unwrap()
        .iter()
        .map(|row| (row.get(0), row.get(1)))
        .collect()
}

/// Starts the tool on owners and accounts with the flag, while a transaction
/// holds a row of accounts, and returns the locks it took in the given mode.
fn locks_taken_with(flag: &str, mode: &str) -> Vec<(String, bool)> {
    create_accounts_with_owners();
    let mut client = connect();
    let (release, blocker) = open_transaction_on_accounts();

    let mut lockwise = lockwise_command("tests/window-long-pause.toml", &["owners", "accounts"], "SELECT 1")
        .arg(flag)
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    while locks_in_mode(&mut client, mode).len() < 2 {
        thread::sleep(Duration::from_millis(20));
    }
    let locks = locks_in_mode(&mut client, mode);

    release.send(()).unwrap();
    blocker.join().unwrap();
    assert!(lockwise.wait().unwrap().success());
    locks
}

#[test]
fn access_exclusive_is_taken_in_the_order_given() {
    let locks = locks_taken_with("--access-exclusive", "AccessExclusiveLock");

    assert_eq!(locks, [("accounts".to_string(), false), ("owners".to_string(), true)]);
}

#[test]
fn share_row_exclusive_is_taken_in_the_order_given() {
    let locks = locks_taken_with("--share-row-exclusive", "ShareRowExclusiveLock");

    assert_eq!(locks, [("accounts".to_string(), false), ("owners".to_string(), true)]);
}

#[test]
fn refuses_both_explicit_locks_at_once() {
    let output = lockwise_command("tests/window.toml", &["accounts"], "SELECT 1")
        .args(["--access-exclusive", "--share-row-exclusive"])
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("not both"));
}

const FAIL_UNLESS_STATEMENT_TIMEOUT_IS_700MS: &str = "DO $$ BEGIN
  IF current_setting('statement_timeout') <> '700ms' THEN
    RAISE EXCEPTION 'statement_timeout is %', current_setting('statement_timeout');
  END IF;
END $$";

#[test]
fn waits_without_the_statement_timeout_and_gives_it_back_to_the_sql() {
    create_accounts_table();
    let (release, holder) = open_transaction("LOCK TABLE accounts IN SHARE UPDATE EXCLUSIVE MODE");
    let releaser = release_after(release, Duration::from_millis(1500));
    let connection = format!("{} options='-c statement_timeout=700ms'", connection_string());

    let output = Command::new(env!("CARGO_BIN_EXE_lockwise"))
        .args(["run", "--conn", &connection, "--preset", "tests/window.toml", "--table", "accounts"])
        .args(["--sql", FAIL_UNLESS_STATEMENT_TIMEOUT_IS_700MS])
        .output()
        .unwrap();
    releaser.join().unwrap();
    holder.join().unwrap();

    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(names(&events(&output)), ["queued", "prelocked", "acquired", "result"]);
}
