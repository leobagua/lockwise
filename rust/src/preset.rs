use serde::Deserialize;
use std::time::Duration;

#[derive(Debug, Deserialize)]
pub struct Preset {
    pub name: String,
    pub max_runtime_s: u64,
    pub schedule: Option<Schedule>,
    pub watcher: Option<Watcher>,
    pub window: Option<Window>,
    #[serde(default)]
    pub kill: Kill,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Schedule {
    /// Pairs of [lock_timeout_ms, sleep_ms], run `repeat` times over.
    Fixed { steps: Vec<[u64; 2]>, repeat: usize },
    /// Random lock_timeout from `timeouts_ms`, sleep with exponential backoff and full jitter.
    Jitter { timeouts_ms: Vec<u64>, base_sleep_ms: u64, max_sleep_ms: u64, attempts: usize },
}

#[derive(Debug, Deserialize, Clone)]
pub struct Watcher {
    pub poll_ms: u64,
    pub budget_blocked_seconds: f64,
    pub queue_cap: i64,
}

#[derive(Debug, Deserialize)]
pub struct Window {
    /// The longest the tables may be paused by one strong lock request.
    pub max_pause_ms: u64,
    pub cooldown_ms: u64,
    pub poll_ms: u64,
    /// The pre-lock keeps VACUUM and ANALYZE out, so it is released this often.
    pub prelock_hold_s: u64,
}

#[derive(Debug, Deserialize, Default, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum Kill {
    #[default]
    None,
    /// Terminates every backend holding a lock on the target tables. Reference only.
    All,
}

pub struct Attempt {
    pub lock_timeout: Duration,
    pub sleep_after: Duration,
}

impl Preset {
    pub fn load(path: &str) -> Result<Preset, String> {
        let text = std::fs::read_to_string(path).map_err(|error| format!("{path}: {error}"))?;
        let preset: Preset = toml::from_str(&text).map_err(|error| format!("{path}: {error}"))?;
        if preset.schedule.is_some() == preset.window.is_some() {
            return Err(format!("{path}: set exactly one of [schedule] and [window]"));
        }
        Ok(preset)
    }

    pub fn attempts(&self, random: &mut Random) -> Vec<Attempt> {
        match self.schedule.as_ref().expect("schedule preset") {
            Schedule::Fixed { steps, repeat } => steps
                .iter()
                .cycle()
                .take(steps.len() * repeat)
                .map(|step| Attempt {
                    lock_timeout: Duration::from_millis(step[0]),
                    sleep_after: Duration::from_millis(step[1]),
                })
                .collect(),
            Schedule::Jitter { timeouts_ms, base_sleep_ms, max_sleep_ms, attempts } => (0..*attempts)
                .map(|attempt| {
                    let ceiling = base_sleep_ms.saturating_mul(1 << attempt.min(30)).min(*max_sleep_ms);
                    Attempt {
                        lock_timeout: Duration::from_millis(timeouts_ms[random.below(timeouts_ms.len() as u64) as usize]),
                        sleep_after: Duration::from_millis(random.below(ceiling + 1)),
                    }
                })
                .collect(),
        }
    }
}

/// xorshift64, enough for jitter and free of dependencies.
pub struct Random(u64);

impl Random {
    pub fn seeded_from_clock() -> Random {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_nanos() as u64)
            .unwrap_or(1);
        Random(nanos | 1)
    }

    pub fn below(&mut self, bound: u64) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0 % bound.max(1)
    }
}
