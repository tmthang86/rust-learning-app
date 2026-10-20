//! Logging, counters and the periodic summary.
//!
//! Logs are JSON lines for journald, one `run_finished` event per `/run`
//! request. Never logged: code, program output, tokens or any header value,
//! the full client IP, the user agent, compiler stderr. Clients are
//! identified by a keyed hash that changes on every process start.

use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use aws_lc_rs::hmac;
use tracing_subscriber::EnvFilter;

use crate::AppState;
use crate::config::LogFormat;

/// How a `/run` request ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Ok,
    CompileError,
    Timeout,
    MemLimit,
    RateLimited,
    AuthFailed,
    Busy,
    BadRequest,
    Internal,
}

impl Outcome {
    pub const ALL: [Outcome; 9] = [
        Outcome::Ok,
        Outcome::CompileError,
        Outcome::Timeout,
        Outcome::MemLimit,
        Outcome::RateLimited,
        Outcome::AuthFailed,
        Outcome::Busy,
        Outcome::BadRequest,
        Outcome::Internal,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Outcome::Ok => "ok",
            Outcome::CompileError => "compile_error",
            Outcome::Timeout => "timeout",
            Outcome::MemLimit => "mem_limit",
            Outcome::RateLimited => "rate_limited",
            Outcome::AuthFailed => "auth_failed",
            Outcome::Busy => "busy",
            Outcome::BadRequest => "bad_request",
            Outcome::Internal => "internal",
        }
    }

    fn index(self) -> usize {
        self as usize
    }

    /// Outcomes that came from the sandbox actually running the code.
    fn ran_code(self) -> bool {
        matches!(
            self,
            Outcome::Ok | Outcome::CompileError | Outcome::Timeout | Outcome::MemLimit
        )
    }
}

/// What a handler tells the request logger about the request. It travels in
/// the response extensions; the gate adds status, timings and the client.
#[derive(Debug, Clone, Default)]
pub struct RunInfo {
    pub outcome: Option<Outcome>,
    pub stage: Option<&'static str>,
    pub queue_ms: Option<u64>,
    pub code_bytes: Option<usize>,
    pub stdout_bytes: Option<usize>,
    pub stderr_bytes: Option<usize>,
    pub truncated: bool,
    /// Which bucket said no, on a 429.
    pub limiter: Option<&'static str>,
    /// Why App Check said no, on a 401/403. Logs only, never the response.
    pub auth_error: Option<&'static str>,
}

/// Keyed hash with a random per-process key (HMAC-SHA256).
pub struct Hasher {
    key: hmac::Key,
}

impl Hasher {
    pub fn new() -> Self {
        let mut bytes = [0u8; 32];
        aws_lc_rs::rand::fill(&mut bytes).expect("system random number generator");
        Self {
            key: hmac::Key::new(hmac::HMAC_SHA256, &bytes),
        }
    }

    pub fn hash(&self, data: &[u8]) -> [u8; 32] {
        let tag = hmac::sign(&self.key, data);
        let mut out = [0u8; 32];
        out.copy_from_slice(tag.as_ref());
        out
    }

    /// First 12 hex characters of the hash: enough to correlate requests
    /// from one client during the day, not enough to identify anyone.
    pub fn short(&self, data: &[u8]) -> String {
        self.hash(data)
            .iter()
            .take(6)
            .map(|b| format!("{b:02x}"))
            .collect()
    }
}

impl Default for Hasher {
    fn default() -> Self {
        Self::new()
    }
}

/// Counts over one summary interval.
#[derive(Debug, Clone, Default)]
pub struct Window {
    pub counts: [u64; Outcome::ALL.len()],
    pub duration_sum_ms: u64,
    pub duration_max_ms: u64,
    pub queue_sum_ms: u64,
    pub queue_max_ms: u64,
}

impl Window {
    pub fn count(&self, outcome: Outcome) -> u64 {
        self.counts[outcome.index()]
    }

    /// Requests that ran code in the sandbox.
    pub fn runs(&self) -> u64 {
        Outcome::ALL
            .iter()
            .filter(|o| o.ran_code())
            .map(|o| self.count(*o))
            .sum()
    }

    /// More than 20 % of at least 10 runs hit the memory limit. Lessons
    /// rarely do, so this means abuse or a host problem.
    pub fn mem_limit_rate_high(&self) -> bool {
        let runs = self.runs();
        runs >= 10 && self.count(Outcome::MemLimit) * 5 > runs
    }
}

/// Counters since start (for `/health`) plus the current summary interval.
pub struct Telemetry {
    pub hasher: Hasher,
    totals: [AtomicU64; Outcome::ALL.len()],
    window: Mutex<Window>,
}

impl Telemetry {
    pub fn new() -> Self {
        Self {
            hasher: Hasher::new(),
            totals: Default::default(),
            window: Mutex::default(),
        }
    }

    pub fn record(&self, outcome: Outcome, duration_ms: u64, queue_ms: Option<u64>) {
        self.totals[outcome.index()].fetch_add(1, Ordering::Relaxed);
        let mut w = self.window.lock().unwrap();
        w.counts[outcome.index()] += 1;
        w.duration_sum_ms += duration_ms;
        w.duration_max_ms = w.duration_max_ms.max(duration_ms);
        if let Some(q) = queue_ms {
            w.queue_sum_ms += q;
            w.queue_max_ms = w.queue_max_ms.max(q);
        }
    }

    pub fn total(&self, outcome: Outcome) -> u64 {
        self.totals[outcome.index()].load(Ordering::Relaxed)
    }

    /// Returns the current interval's numbers and starts a new interval.
    pub fn take_window(&self) -> Window {
        std::mem::take(&mut *self.window.lock().unwrap())
    }
}

impl Default for Telemetry {
    fn default() -> Self {
        Self::new()
    }
}

/// Sets up tracing: JSON lines (fields at the top level, so
/// `jq 'select(.event=="summary")'` works) or readable text.
pub fn init_tracing(format: LogFormat) {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let builder = tracing_subscriber::fmt().with_env_filter(filter);
    match format {
        LogFormat::Json => builder
            .json()
            .flatten_event(true)
            .with_current_span(false)
            .with_span_list(false)
            .init(),
        LogFormat::Text => builder.init(),
    }
}

/// Every 60 seconds: one `summary` line, and a `warn` when the memory-limit
/// rate looks wrong.
pub async fn summary_loop(state: Arc<AppState>) {
    let mut tick = tokio::time::interval(Duration::from_secs(60));
    tick.tick().await;
    loop {
        tick.tick().await;
        log_summary(&state);
    }
}

pub fn log_summary(state: &AppState) {
    let w = state.telemetry.take_window();
    let requests: u64 = w.counts.iter().sum();
    let ran = w.runs().max(1);
    let slots_busy = state
        .max_jobs
        .saturating_sub(state.slots.available_permits());
    let (ip_keys, token_keys) = state.rate.key_counts();
    tracing::info!(
        event = "summary",
        requests,
        ok = w.count(Outcome::Ok),
        compile_error = w.count(Outcome::CompileError),
        timeout = w.count(Outcome::Timeout),
        mem_limit = w.count(Outcome::MemLimit),
        rate_limited = w.count(Outcome::RateLimited),
        auth_failed = w.count(Outcome::AuthFailed),
        busy = w.count(Outcome::Busy),
        bad_request = w.count(Outcome::BadRequest),
        internal = w.count(Outcome::Internal),
        duration_avg_ms = w.duration_sum_ms / requests.max(1),
        duration_max_ms = w.duration_max_ms,
        queue_wait_avg_ms = w.queue_sum_ms / ran,
        queue_wait_max_ms = w.queue_max_ms,
        slots_busy,
        queued = state.waiting.load(Ordering::Relaxed),
        ip_keys,
        token_keys,
        key_cache_age_secs = state.key_cache_age_secs(),
        "summary"
    );
    if w.mem_limit_rate_high() {
        tracing::warn!(
            event = "mem_limit_rate_high",
            mem_limit = w.count(Outcome::MemLimit),
            runs = w.runs(),
            "more than 20% of runs hit the memory limit: abuse or a host problem"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hasher_is_keyed_and_stable_within_a_process() {
        let a = Hasher::new();
        let b = Hasher::new();
        assert_eq!(a.hash(b"x"), a.hash(b"x"));
        assert_ne!(a.hash(b"x"), a.hash(b"y"));
        assert_ne!(a.hash(b"x"), b.hash(b"x"), "each process has its own key");
        assert_eq!(a.short(b"1.2.3.4").len(), 12);
    }

    #[test]
    fn mem_limit_alert_needs_volume_and_share() {
        let mut w = Window::default();
        w.counts[Outcome::MemLimit.index()] = 9;
        assert!(!w.mem_limit_rate_high(), "fewer than 10 runs");
        w.counts[Outcome::Ok.index()] = 1;
        assert!(w.mem_limit_rate_high(), "9 of 10");
        w.counts[Outcome::Ok.index()] = 36;
        assert!(!w.mem_limit_rate_high(), "9 of 45 is exactly 20%");
        w.counts[Outcome::Ok.index()] = 35;
        assert!(w.mem_limit_rate_high(), "9 of 44 is over 20%");
        // Requests that never ran code don't dilute the share.
        w.counts[Outcome::RateLimited.index()] = 1000;
        assert!(w.mem_limit_rate_high());
    }

    #[test]
    fn counters_and_windows() {
        let t = Telemetry::new();
        t.record(Outcome::Ok, 100, Some(5));
        t.record(Outcome::Ok, 300, Some(15));
        t.record(Outcome::CompileError, 50, None);
        assert_eq!(t.total(Outcome::Ok), 2);
        let w = t.take_window();
        assert_eq!(w.runs(), 3);
        assert_eq!(w.duration_max_ms, 300);
        assert_eq!(w.queue_max_ms, 15);
        assert_eq!(t.take_window().runs(), 0, "window resets");
        assert_eq!(t.total(Outcome::Ok), 2, "totals keep counting");
    }
}
