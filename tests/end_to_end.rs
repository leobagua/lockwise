use postgres::{Client, NoTls};
use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::process::{Command, Output, Stdio};
use std::sync::mpsc::{channel, Sender};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const ADD_COLUMN: &str = "ALTER TABLE accounts ADD COLUMN note text";

fn connection_string() -> String {
    std::env::var("LOCKWISE_TEST_CONN").expect("run the tests through tests/run.sh")
}

fn connect() -> Client {
    Client::connect(&connection_string(), NoTls).unwrap()
}

fn create_accounts_table() -> Client {
    let mut client = connect();
    client
        .batch_execute("DROP TABLE IF EXISTS accounts; CREATE TABLE accounts (id int PRIMARY KEY); INSERT INTO accounts VALUES (1)")
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

fn lockwise_command(preset: &str) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_lockwise"));
    command
        .args(["run", "--conn", &connection_string(), "--preset", preset])
        .args(["--lock", "accounts:ael", "--sql", ADD_COLUMN]);
    command
}

fn run_lockwise(preset: &str) -> Output {
    lockwise_command(preset).output().unwrap()
}

fn events(output: &Output) -> Vec<Value> {
    String::from_utf8_lossy(&output.stdout).lines().map(|line| serde_json::from_str(line).unwrap()).collect()
}

fn names(events: &[Value]) -> Vec<&str> {
    events.iter().map(|event| event["event"].as_str().unwrap()).collect()
}

fn note_column_exists(client: &mut Client) -> bool {
    let columns: i64 = client
        .query_one(
            "SELECT count(*) FROM information_schema.columns WHERE table_name = 'accounts' AND column_name = 'note'",
            &[],
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
    assert!(note_column_exists(&mut client));
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
    assert!(!note_column_exists(&mut client));
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
    assert!(note_column_exists(&mut client));
}

#[test]
fn reads_and_writes_keep_running_while_the_tool_waits_on_the_weak_lock() {
    let mut client = create_accounts_table();
    let (release, blocker) = open_transaction_on_accounts();
    thread::sleep(Duration::from_secs(1));

    let mut lockwise = lockwise_command("tests/window.toml").stdout(Stdio::piped()).spawn().unwrap();
    let mut lines = BufReader::new(lockwise.stdout.take().unwrap()).lines();
    let waiting = lines.by_ref().map(Result::unwrap).find(|line| line.contains(r#""event":"waiting""#));
    assert!(waiting.is_some());

    let weak_locks: i64 = client
        .query_one(
            "SELECT count(*) FROM pg_locks
              WHERE relation = 'accounts'::regclass AND mode = 'ShareUpdateExclusiveLock' AND granted",
            &[],
        )
        .unwrap()
        .get(0);
    assert_eq!(weak_locks, 1);

    client.batch_execute("SET lock_timeout = '200ms'; INSERT INTO accounts VALUES (2)").unwrap();
    let rows: i64 = client.query_one("SELECT count(*) FROM accounts", &[]).unwrap().get(0);
    assert_eq!(rows, 2);

    release.send(()).unwrap();
    blocker.join().unwrap();
    assert!(lockwise.wait().unwrap().success());
}
