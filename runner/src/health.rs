//! `/health`, liveness tracking and the idle self-check.
//!
//! "Healthy" means the sandbox recently gave a real compiler verdict (a
//! program ran, or the compiler reported errors), the App Check keys are
//! loaded (when required) and the disk has room. Jobs killed by the host,
//! timeouts and internal errors don't count as proof of life, so a host
//! that keeps failing jobs goes unhealthy even under load.

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::Json;
use axum::extract::State;
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde_json::json;

use crate::AppState;
use crate::sandbox::check_sandbox;
use crate::telemetry::Outcome;

/// Unhealthy when no job has given a compiler verdict for this long.
pub const MAX_IDLE_SECS: u64 = 1800;
/// The idle self-check runs when nothing good happened for this long.
const SELF_CHECK_AFTER: Duration = Duration::from_secs(10 * 60);
/// Free disk below this (MB) is unhealthy.
pub const DEFAULT_MIN_DISK_MB: u64 = 2048;

pub struct HealthState {
    started: Instant,
    last_good_job: Mutex<Option<Instant>>,
    /// Unhealthy below this much free disk, in MB.
    pub min_disk_mb: u64,
}

impl HealthState {
    pub fn new(min_disk_mb: u64) -> Self {
        Self {
            started: Instant::now(),
            last_good_job: Mutex::new(None),
            min_disk_mb,
        }
    }

    /// Records a job that proves the sandbox works.
    pub fn mark_good(&self) {
        *self.last_good_job.lock().unwrap() = Some(Instant::now());
    }

    pub fn secs_since_good_job(&self) -> Option<u64> {
        self.last_good_job
            .lock()
            .unwrap()
            .map(|t| t.elapsed().as_secs())
    }

    pub fn uptime_secs(&self) -> u64 {
        self.started.elapsed().as_secs()
    }
}

/// Free space, in MB, where Docker keeps images and snapshots:
/// `/var/lib/containerd` (Docker 29's containerd image store), else
/// `/var/lib/docker`, else the root filesystem.
pub fn disk_free_mb() -> Option<u64> {
    ["/var/lib/containerd", "/var/lib/docker", "/"]
        .into_iter()
        .map(Path::new)
        .filter(|p| p.exists())
        .find_map(free_mb_at)
}

pub fn free_mb_at(path: &Path) -> Option<u64> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let c_path = CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut stat = std::mem::MaybeUninit::<libc::statvfs>::zeroed();
    // SAFETY: `c_path` is a valid NUL-terminated string and `stat` points to
    // writable memory of the right type; statvfs only writes into it.
    let rc = unsafe { libc::statvfs(c_path.as_ptr(), stat.as_mut_ptr()) };
    if rc != 0 {
        return None;
    }
    // SAFETY: statvfs returned 0, so it filled in the struct.
    let stat = unsafe { stat.assume_init() };
    // Blocks available to unprivileged users, times the fragment size. The
    // field types differ by platform (u32 on macOS), hence the casts.
    #[allow(clippy::unnecessary_cast)]
    Some((stat.f_bavail as u64).saturating_mul(stat.f_frsize as u64) / (1024 * 1024))
}

/// `GET /health`: JSON, no auth, no rate limit, never cached.
pub async fn health(State(state): State<Arc<AppState>>) -> Response {
    let since_good = state.health.secs_since_good_job();
    let keys_ready = state.keys_ready();
    let disk = disk_free_mb();
    let healthy = since_good.is_some_and(|s| s <= MAX_IDLE_SECS)
        && keys_ready
        && disk.is_none_or(|d| d >= state.health.min_disk_mb);
    let t = &state.telemetry;
    let body = json!({
        "status": if healthy { "ok" } else { "unhealthy" },
        "lastGoodJobSecsAgo": since_good,
        "keysReady": keys_ready,
        "diskFreeMb": disk,
        "runs": {
            "ok": t.total(Outcome::Ok),
            "compileError": t.total(Outcome::CompileError),
            "timeout": t.total(Outcome::Timeout),
            "memLimit": t.total(Outcome::MemLimit),
            "rateLimited": t.total(Outcome::RateLimited),
            "busy": t.total(Outcome::Busy),
            "internal": t.total(Outcome::Internal),
        },
        "uptimeSecs": state.health.uptime_secs(),
        "version": env!("CARGO_PKG_VERSION"),
    });
    let status = if healthy {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    let mut res = (status, Json(body)).into_response();
    res.headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    res
}

/// Runs `check_sandbox` and records success as liveness.
pub async fn self_check(state: &AppState) -> Result<(), String> {
    check_sandbox(&state.sandbox, &state.limits).await?;
    state.health.mark_good();
    Ok(())
}

/// What one pass of the idle check did.
#[derive(Debug, PartialEq, Eq)]
pub enum IdleCheck {
    /// A good job happened recently; nothing to do.
    Fresh,
    /// Idle, but no job slot was free; try again later.
    NoSlot,
    /// Idle: the self-check ran with this result.
    Ran(Result<(), String>),
}

/// One pass of the idle check: if no good job happened within `after`, run a
/// hello-world through the sandbox (in a free slot) and record the result.
pub async fn idle_check_once(state: &AppState, after: Duration) -> IdleCheck {
    let idle = state
        .health
        .secs_since_good_job()
        .is_none_or(|s| s >= after.as_secs());
    if !idle {
        return IdleCheck::Fresh;
    }
    let Ok(_permit) = state.slots.try_acquire() else {
        return IdleCheck::NoSlot;
    };
    IdleCheck::Ran(self_check(state).await)
}

/// When no good job happened for 10 minutes, runs a hello-world through the
/// sandbox so a quiet runner stays provably alive (and a broken host is
/// noticed). It needs a free slot; if there is none it retries in 30 s.
/// Sustained load never makes the runner look unhealthy, because load
/// produces good jobs.
pub async fn idle_check_loop(state: Arc<AppState>) {
    loop {
        tokio::time::sleep(Duration::from_secs(30)).await;
        match idle_check_once(&state, SELF_CHECK_AFTER).await {
            IdleCheck::Ran(Ok(())) => tracing::info!(event = "idle_self_check", ok = true),
            IdleCheck::Ran(Err(e)) => tracing::error!(event = "idle_self_check", ok = false, "{e}"),
            IdleCheck::Fresh | IdleCheck::NoSlot => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn statvfs_reads_the_root_filesystem() {
        let mb = free_mb_at(Path::new("/")).expect("statvfs on /");
        assert!(mb > 0);
        assert!(free_mb_at(Path::new("/definitely/not/here")).is_none());
        assert!(disk_free_mb().is_some());
    }

    #[tokio::test]
    async fn idle_check_runs_only_when_idle_and_a_slot_is_free() {
        use crate::sandbox::{Limits, Sandbox};
        let mut st = AppState::for_tests(Sandbox::Local, Limits::default());
        st.slots = tokio::sync::Semaphore::new(0);
        let after = Duration::from_secs(600);
        assert_eq!(idle_check_once(&st, after).await, IdleCheck::NoSlot);
        assert_eq!(st.health.secs_since_good_job(), None);

        st.slots.add_permits(1);
        assert_eq!(idle_check_once(&st, after).await, IdleCheck::Ran(Ok(())));
        assert_eq!(st.health.secs_since_good_job(), Some(0));
        assert_eq!(st.slots.available_permits(), 1, "the slot is given back");

        // Recently good: nothing to do. With a zero threshold it runs again.
        assert_eq!(idle_check_once(&st, after).await, IdleCheck::Fresh);
        assert_eq!(
            idle_check_once(&st, Duration::ZERO).await,
            IdleCheck::Ran(Ok(()))
        );
    }

    #[test]
    fn liveness_tracking() {
        let h = HealthState::new(0);
        assert_eq!(h.secs_since_good_job(), None);
        h.mark_good();
        assert_eq!(h.secs_since_good_job(), Some(0));
    }
}
