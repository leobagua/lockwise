mod engine;
mod preset;
mod window;

use engine::{Job, LockRequest};
use preset::Preset;
use std::process::ExitCode;

const USAGE: &str = "usage: lockwise run --conn <connection string> --preset <file.toml> --lock <table:ael|sre|sue> [--lock ...] [--sql <ddl>]";

struct Arguments {
    connection: String,
    preset: String,
    locks: Vec<LockRequest>,
    sql: Option<String>,
}

fn parse_arguments() -> Result<Arguments, String> {
    let mut words = std::env::args().skip(1);
    if words.next().as_deref() != Some("run") {
        return Err(USAGE.to_string());
    }
    let (mut connection, mut preset, mut locks, mut sql) = (None, None, Vec::new(), None);
    while let Some(flag) = words.next() {
        let value = words.next().ok_or(format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--conn" => connection = Some(value),
            "--preset" => preset = Some(value),
            "--lock" => locks.push(LockRequest::parse(&value)?),
            "--sql" => sql = Some(value),
            other => return Err(format!("unknown flag {other}\n{USAGE}")),
        }
    }
    if locks.is_empty() {
        return Err(USAGE.to_string());
    }
    Ok(Arguments {
        connection: connection.ok_or(USAGE)?,
        preset: preset.ok_or(USAGE)?,
        locks,
        sql,
    })
}

fn main() -> ExitCode {
    let outcome = parse_arguments().and_then(|arguments| {
        let preset = Preset::load(&arguments.preset)?;
        let job = Job {
            connection: &arguments.connection,
            preset: &preset,
            locks: &arguments.locks,
            sql: arguments.sql.as_deref(),
        };
        match &preset.window {
            Some(window) => window::run(&job, window),
            None => engine::run(&job),
        }
        .map_err(|error| error.to_string())
    });
    match outcome {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::from(2),
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}
