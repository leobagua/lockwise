mod engine;
mod preset;
mod window;

use engine::Job;
use preset::Preset;
use std::process::ExitCode;

const USAGE: &str = "usage: lockwise run --conn <connection string> --preset <file.toml> --table <name> [--table ...] [--access-exclusive] [--sql <ddl>]";

struct Arguments {
    connection: String,
    preset: String,
    tables: Vec<String>,
    access_exclusive: bool,
    sql: Option<String>,
}

fn parse_arguments() -> Result<Arguments, String> {
    let mut words = std::env::args().skip(1);
    if words.next().as_deref() != Some("run") {
        return Err(USAGE.to_string());
    }
    let (mut connection, mut preset, mut tables, mut access_exclusive, mut sql) = (None, None, Vec::new(), false, None);
    while let Some(flag) = words.next() {
        if flag == "--access-exclusive" {
            access_exclusive = true;
            continue;
        }
        let value = words.next().ok_or(format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--conn" => connection = Some(value),
            "--preset" => preset = Some(value),
            "--table" => tables.push(value),
            "--sql" => sql = Some(value),
            other => return Err(format!("unknown flag {other}\n{USAGE}")),
        }
    }
    if tables.is_empty() {
        return Err(USAGE.to_string());
    }
    Ok(Arguments {
        connection: connection.ok_or(USAGE)?,
        preset: preset.ok_or(USAGE)?,
        tables,
        access_exclusive,
        sql,
    })
}

fn main() -> ExitCode {
    let outcome = parse_arguments().and_then(|arguments| {
        let preset = Preset::load(&arguments.preset)?;
        let job = Job {
            connection: &arguments.connection,
            preset: &preset,
            tables: &arguments.tables,
            access_exclusive: arguments.access_exclusive,
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
