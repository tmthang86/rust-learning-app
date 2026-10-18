use std::sync::Arc;
use std::time::Duration;

use rust_runner::sandbox::{Limits, Sandbox};
use rust_runner::{AppState, app};
use tokio::sync::Semaphore;

fn env_or<T: std::str::FromStr>(key: &str, default: T) -> T {
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let sandbox = match std::env::var("RUNNER_SANDBOX").as_deref() {
        Ok("local") => {
            tracing::warn!("RUNNER_SANDBOX=local runs code unsandboxed. Development only.");
            Sandbox::Local
        }
        _ => Sandbox::Docker {
            image: std::env::var("RUNNER_IMAGE")
                .unwrap_or_else(|_| "rust-runner-sandbox".to_string()),
        },
    };

    let defaults = Limits::default();
    let limits = Limits {
        run_timeout: Duration::from_secs(env_or("RUNNER_RUN_TIMEOUT_SECS", 5)),
        job_timeout: Duration::from_secs(env_or("RUNNER_JOB_TIMEOUT_SECS", 20)),
        memory_mb: env_or("RUNNER_MEMORY_MB", defaults.memory_mb),
        ..defaults
    };

    let state = Arc::new(AppState {
        sandbox,
        limits,
        slots: Semaphore::new(env_or("RUNNER_MAX_JOBS", 4)),
    });

    let addr = std::env::var("RUNNER_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
    let listener = tokio::net::TcpListener::bind(&addr).await.expect("bind address");
    tracing::info!("listening on {addr}");
    axum::serve(listener, app(state)).await.expect("server error");
}
