//! HTTP service that compiles and runs Rust code for the Learn Rust app.
//!
//! See `docs/production-design.md` for the design: App Check on `/run`,
//! rate limits, the gVisor sandbox, health and deployment.

pub mod app_check;
pub mod client_ip;
pub mod config;
pub mod errors;
pub mod gate;
pub mod health;
pub mod ratelimit;
pub mod sandbox;
pub mod telemetry;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use axum::extract::rejection::JsonRejection;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::{HeaderName, HeaderValue, Method, StatusCode, header};
use axum::middleware::{from_fn, from_fn_with_state};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use tokio::sync::{Semaphore, TryAcquireError};
use tower_http::cors::{AllowOrigin, CorsLayer};
use tower_http::timeout::TimeoutLayer;

use app_check::AppCheck;
use client_ip::TrustedProxies;
use config::Config;
use errors::ApiError;
use health::HealthState;
use ratelimit::RateLimits;
use sandbox::{Limits, RunOutput, Sandbox, Stage};
use telemetry::{Outcome, RunInfo, Telemetry};

/// Largest source file accepted, in bytes.
pub const MAX_CODE_BYTES: usize = 64 * 1024;

/// Largest request body of `/grade`: JSON escaping can double the size of
/// the code and of the test fields, which are capped on their decoded size.
pub const MAX_GRADE_BODY_BYTES: usize = 2 * (MAX_CODE_BYTES + rr_grade::MAX_TESTS_BYTES) + 1024;

pub struct AppState {
    pub sandbox: Sandbox,
    pub limits: Limits,
    /// Caps how many jobs run at once; extra requests wait their turn.
    pub slots: Semaphore,
    /// The number of slots, for the summary.
    pub max_jobs: usize,
    /// How long a request may wait for a free slot before getting a 503.
    pub queue_timeout: Duration,
    /// How many requests may wait for a slot at once; more get a 503 at once.
    pub max_queued: usize,
    /// Requests waiting for a slot right now.
    pub waiting: AtomicUsize,
    /// Set once the "IPv6 client seen" line has been logged.
    pub ipv6_logged: AtomicBool,
    /// Web origins allowed to call the API from a browser. Empty allows any
    /// origin, which is only meant for local development.
    pub allowed_origins: Vec<String>,
    /// `Some` when App Check is required on `/run`.
    pub app_check: Option<AppCheck>,
    /// Proxies whose `X-Forwarded-For` is believed.
    pub proxies: TrustedProxies,
    pub rate: RateLimits,
    pub telemetry: Telemetry,
    pub health: HealthState,
}

impl AppState {
    /// State for tests: no App Check, no rate limits, two job slots, any
    /// CORS origin. Nothing here reads environment variables.
    pub fn for_tests(sandbox: Sandbox, limits: Limits) -> Self {
        Self {
            sandbox,
            limits,
            slots: Semaphore::new(2),
            max_jobs: 2,
            queue_timeout: Duration::from_secs(10),
            max_queued: 16,
            waiting: AtomicUsize::new(0),
            ipv6_logged: AtomicBool::new(false),
            allowed_origins: Vec::new(),
            app_check: None,
            proxies: TrustedProxies::default(),
            rate: RateLimits::disabled(),
            telemetry: Telemetry::new(),
            health: HealthState::new(0),
        }
    }

    /// State for the server, from a validated config.
    pub fn from_config(cfg: &Config, sandbox: Sandbox, app_check: Option<AppCheck>) -> Self {
        Self {
            sandbox,
            limits: cfg.limits.clone(),
            slots: Semaphore::new(cfg.max_jobs),
            max_jobs: cfg.max_jobs,
            queue_timeout: cfg.queue_timeout,
            max_queued: cfg.max_queued,
            waiting: AtomicUsize::new(0),
            ipv6_logged: AtomicBool::new(false),
            allowed_origins: cfg.allowed_origins.clone(),
            app_check,
            proxies: cfg.trusted_proxies.clone(),
            rate: RateLimits::new(cfg.rate),
            telemetry: Telemetry::new(),
            health: HealthState::new(health::DEFAULT_MIN_DISK_MB),
        }
    }

    /// Whether `/run` can verify tokens (always true when App Check is off).
    pub fn keys_ready(&self) -> bool {
        self.app_check.as_ref().is_none_or(|a| a.cache().ready())
    }

    pub fn key_cache_age_secs(&self) -> Option<u64> {
        self.app_check.as_ref().and_then(|a| a.cache().age_secs())
    }

    /// Stops accepting jobs: queued and new requests get 503 `shutting_down`;
    /// jobs already running finish.
    pub fn begin_shutdown(&self) {
        self.slots.close();
    }
}

#[derive(Deserialize)]
pub struct RunRequest {
    pub code: String,
}

#[derive(Deserialize)]
pub struct GradeRequest {
    pub code: String,
    pub tests: Vec<rr_grade::TestSpec>,
}

pub fn app(state: Arc<AppState>) -> Router {
    let any = state.allowed_origins.is_empty() || state.allowed_origins.iter().any(|o| o == "*");
    let origins = if any {
        AllowOrigin::any()
    } else {
        AllowOrigin::list(state.allowed_origins.iter().filter_map(|o| {
            let value = HeaderValue::from_str(o).ok();
            if value.is_none() {
                tracing::warn!("ignoring invalid CORS origin {o:?}");
            }
            value
        }))
    };
    let cors = CorsLayer::new()
        .allow_origin(origins)
        .allow_methods([Method::GET, Method::POST])
        .allow_headers([
            header::CONTENT_TYPE,
            HeaderName::from_static(gate::APP_CHECK_HEADER),
        ])
        // Without these the browser hides the headers from Flutter web.
        .expose_headers([header::RETRY_AFTER, HeaderName::from_static("x-request-id")])
        .max_age(Duration::from_secs(3600));
    // Upper bound for a whole request: waiting for a slot plus running the job.
    let request_timeout = state.queue_timeout + state.limits.job_timeout + Duration::from_secs(5);

    // `/run` and `/grade` go through the gate (IP limits, App Check, token
    // limits), one request costing one token on either.
    let run_routes = Router::new()
        // JSON escaping can double the size of code; the real limit is
        // checked on the decoded code below.
        .route(
            "/run",
            post(run).layer(DefaultBodyLimit::max(2 * MAX_CODE_BYTES + 1024)),
        )
        .route(
            "/grade",
            post(grade).layer(DefaultBodyLimit::max(MAX_GRADE_BODY_BYTES)),
        )
        .layer(TimeoutLayer::with_status_code(
            StatusCode::REQUEST_TIMEOUT,
            request_timeout,
        ))
        .route_layer(from_fn_with_state(state.clone(), gate::gate));

    Router::new()
        .route("/health", get(health::health))
        .merge(run_routes)
        .layer(cors)
        .layer(from_fn(gate::request_id))
        .with_state(state)
}

/// Decrements the waiter count when a request stops waiting, however it ends
/// (including the client disconnecting).
struct Waiting<'a>(&'a AtomicUsize);

impl Drop for Waiting<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

async fn run(
    State(state): State<Arc<AppState>>,
    payload: Result<Json<RunRequest>, JsonRejection>,
) -> Result<Response, ApiError> {
    let req = match payload {
        Ok(Json(req)) => req,
        Err(rejection) => {
            let status = rejection.status();
            return Err(if status == StatusCode::PAYLOAD_TOO_LARGE {
                ApiError::code_too_long()
            } else {
                ApiError::bad_request(status, rejection.body_text())
            });
        }
    };
    let code_bytes = req.code.len();
    let sized = |e: ApiError| e.with_info(|i| i.code_bytes = Some(code_bytes));
    if req.code.trim().is_empty() {
        return Err(sized(ApiError::code_empty()));
    }
    if code_bytes > MAX_CODE_BYTES {
        return Err(sized(ApiError::code_too_long()));
    }

    let (_permit, queue_ms) = acquire_slot(&state).await.map_err(sized)?;

    match state.sandbox.run(&req.code, &state.limits).await {
        Ok(output) => {
            if output.compiler_verdict {
                state.health.mark_good();
            }
            let info = run_info(&output, code_bytes, queue_ms);
            let mut res = Json(output).into_response();
            res.extensions_mut().insert(info);
            Ok(res)
        }
        Err(e) => {
            tracing::error!("sandbox failed: {e}");
            Err(sized(ApiError::internal()).with_info(|i| i.queue_ms = Some(queue_ms)))
        }
    }
}

/// Takes a job slot at once if one is free; otherwise queues, within the
/// cap. Returns the permit and how long the request waited, in milliseconds.
async fn acquire_slot(
    state: &AppState,
) -> Result<(tokio::sync::SemaphorePermit<'_>, u64), ApiError> {
    let queued_at = Instant::now();
    let permit = match state.slots.try_acquire() {
        Ok(permit) => permit,
        Err(TryAcquireError::Closed) => return Err(ApiError::shutting_down()),
        Err(TryAcquireError::NoPermits) => {
            if state.waiting.fetch_add(1, Ordering::SeqCst) >= state.max_queued {
                state.waiting.fetch_sub(1, Ordering::SeqCst);
                return Err(ApiError::busy());
            }
            let _waiting = Waiting(&state.waiting);
            match tokio::time::timeout(state.queue_timeout, state.slots.acquire()).await {
                Ok(Ok(permit)) => permit,
                Ok(Err(_)) => return Err(ApiError::shutting_down()),
                Err(_) => return Err(ApiError::busy()),
            }
        }
    };
    Ok((permit, queued_at.elapsed().as_millis() as u64))
}

/// `POST /grade {code, tests}`: like `/run`, but the code is compiled
/// together with the tests and the answer holds one result per test.
async fn grade(
    State(state): State<Arc<AppState>>,
    payload: Result<Json<GradeRequest>, JsonRejection>,
) -> Result<Response, ApiError> {
    let req = match payload {
        Ok(Json(req)) => req,
        Err(rejection) => {
            let status = rejection.status();
            return Err(if status == StatusCode::PAYLOAD_TOO_LARGE {
                ApiError::code_too_long()
            } else {
                ApiError::bad_request(status, rejection.body_text())
            });
        }
    };
    let code_bytes = req.code.len();
    let sized = |e: ApiError| {
        e.with_info(|i| {
            i.code_bytes = Some(code_bytes);
            i.endpoint = Some("grade");
        })
    };
    if req.code.trim().is_empty() {
        return Err(sized(ApiError::code_empty()));
    }
    if code_bytes > MAX_CODE_BYTES {
        return Err(sized(ApiError::code_too_long()));
    }
    if let Err(message) = rr_grade::validate(&req.tests) {
        return Err(sized(ApiError::new(
            StatusCode::BAD_REQUEST,
            "tests_invalid",
            message,
        )));
    }

    let (_permit, queue_ms) = acquire_slot(&state).await.map_err(sized)?;

    match state
        .sandbox
        .grade(&req.code, &req.tests, &state.limits)
        .await
    {
        Ok(output) => {
            if output.run.compiler_verdict {
                state.health.mark_good();
            }
            let mut info = run_info(&output.run, code_bytes, queue_ms);
            info.endpoint = Some("grade");
            info.tests_total = Some(output.tests.len());
            info.tests_passed = Some(
                output
                    .tests
                    .iter()
                    .filter(|t| t.status == rr_grade::Status::Pass)
                    .count(),
            );
            let mut res = Json(output).into_response();
            res.extensions_mut().insert(info);
            Ok(res)
        }
        Err(e) => {
            tracing::error!("sandbox failed: {e}");
            Err(sized(ApiError::internal()).with_info(|i| i.queue_ms = Some(queue_ms)))
        }
    }
}

fn run_info(output: &RunOutput, code_bytes: usize, queue_ms: u64) -> RunInfo {
    let (outcome, stage) = if output.mem_limit {
        (Outcome::MemLimit, output.stage)
    } else {
        (
            match output.stage {
                Stage::Compile => Outcome::CompileError,
                // The program ran; it either finished cleanly or failed on
                // its own (a panic, a non-zero exit).
                Stage::Run if output.success => Outcome::Ok,
                Stage::Run => Outcome::RunFailed,
                Stage::Timeout => Outcome::Timeout,
            },
            output.stage,
        )
    };
    RunInfo {
        outcome: Some(outcome),
        stage: Some(match stage {
            Stage::Compile => "compile",
            Stage::Run => "run",
            Stage::Timeout => "timeout",
        }),
        queue_ms: Some(queue_ms),
        code_bytes: Some(code_bytes),
        stdout_bytes: Some(output.stdout.len()),
        stderr_bytes: Some(output.stderr.len()),
        truncated: output.truncated,
        ..RunInfo::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn output(success: bool, stage: Stage) -> RunOutput {
        RunOutput {
            success,
            stage,
            stdout: String::new(),
            stderr: String::new(),
            warnings: String::new(),
            duration_ms: 1,
            mem_limit: false,
            compiler_verdict: true,
            truncated: false,
        }
    }

    #[test]
    fn run_info_separates_clean_runs_from_failed_ones() {
        let info = |o: &RunOutput| run_info(o, 10, 0).outcome.unwrap();
        assert_eq!(info(&output(true, Stage::Run)), Outcome::Ok);
        // A panic or non-zero exit: the program ran, but did not succeed.
        assert_eq!(info(&output(false, Stage::Run)), Outcome::RunFailed);
        assert_eq!(info(&output(false, Stage::Compile)), Outcome::CompileError);
        assert_eq!(info(&output(false, Stage::Timeout)), Outcome::Timeout);
        let mut oom = output(false, Stage::Run);
        oom.mem_limit = true;
        assert_eq!(info(&oom), Outcome::MemLimit);
    }

    #[test]
    fn run_info_takes_truncated_from_the_output_flag() {
        let mut o = output(true, Stage::Run);
        o.stdout = "[output truncated]".into();
        assert!(!run_info(&o, 1, 0).truncated, "text alone must not count");
        o.truncated = true;
        assert!(run_info(&o, 1, 0).truncated);
    }
}
