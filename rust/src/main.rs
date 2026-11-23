mod engine;
mod preset;
mod window;

use engine::Job;
use preset::Preset;
use std::process::ExitCode;

const USAGE: &str = "usage: lockwise run --conn <connection string> --preset <file.toml> --table <name> [--table ...] [--access-exclusive | --share-row-exclusive] [--sql <ddl>]";

struct Arguments {
    connection: String,
    preset: String,
    tables: Vec<String>,
    explicit_lock: Option<&'static str>,
    sql: Option<String>,
}

fn parse_arguments() -> Result<Arguments, String> {
    let mut words = std::env::args().skip(1);
    if words.next().as_deref() != Some("run") {
        return Err(USAGE.to_string());
    }
    let (mut connection, mut preset, mut tables, mut sql) = (None, None, Vec::new(), None);
    let (mut access_exclusive, mut share_row_exclusive) = (false, false);
    while let Some(flag) = words.next() {
        match flag.as_str() {
            "--access-exclusive" => {
                access_exclusive = true;
                continue;
            }
            "--share-row-exclusive" => {
                share_row_exclusive = true;
                continue;
            }
            _ => {}
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
    let explicit_lock = match (access_exclusive, share_row_exclusive) {
        (true, true) => return Err("choose --access-exclusive or --share-row-exclusive, not both".to_string()),
        (true, false) => Some("ACCESS EXCLUSIVE"),
        (false, true) => Some("SHARE ROW EXCLUSIVE"),
        (false, false) => None,
    };
    Ok(Arguments {
        connection: connection.ok_or(USAGE)?,
        preset: preset.ok_or(USAGE)?,
        tables,
        explicit_lock,
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
            explicit_lock: arguments.explicit_lock,
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
