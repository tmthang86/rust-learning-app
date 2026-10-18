use std::sync::Arc;
use std::time::Duration;

use rust_runner::sandbox::{Limits, Sandbox, check_sandbox, reap_all_job_containers};
use rust_runner::{AppState, app};
use tokio::sync::Semaphore;

fn env_or<T: std::str::FromStr>(key: &str, default: T) -> T {
    match std::env::var(key) {
        Ok(v) => v
            .parse()
            .unwrap_or_else(|_| fail(&format!("{key} has an invalid value: {v}"))),
        Err(_) => default,
    }
}

fn fail(message: &str) -> ! {
    eprintln!("rust-runner: {message}");
    std::process::exit(2);
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let term = async {
        if let Ok(mut s) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            s.recv().await;
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();
    tokio::select! { _ = ctrl_c => {}, _ = term => {} }
    tracing::info!("shutting down: finishing jobs in progress");
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let defaults = Limits::default();
    let limits = Limits {
        compile_timeout: Duration::from_secs(env_or("RUNNER_COMPILE_TIMEOUT_SECS", 10)),
        run_timeout: Duration::from_secs(env_or("RUNNER_RUN_TIMEOUT_SECS", 5)),
        job_timeout: Duration::from_secs(env_or("RUNNER_JOB_TIMEOUT_SECS", 20)),
        memory_mb: env_or("RUNNER_MEMORY_MB", defaults.memory_mb),
        ..defaults
    };
    if let Err(e) = limits.validate() {
        fail(&e);
    }
    let max_jobs: usize = env_or("RUNNER_MAX_JOBS", 4);
    if max_jobs == 0 {
        fail("RUNNER_MAX_JOBS must be at least 1");
    }
    let queue_timeout = Duration::from_secs(env_or("RUNNER_QUEUE_TIMEOUT_SECS", 10));
    if queue_timeout > Duration::from_secs(600) {
        fail("RUNNER_QUEUE_TIMEOUT_SECS must be at most 600");
    }

    let sandbox = match std::env::var("RUNNER_SANDBOX").as_deref() {
        Ok("local") => {
            tracing::warn!("RUNNER_SANDBOX=local runs code unsandboxed. Development only.");
            Sandbox::Local
        }
        _ => {
            let runtime = std::env::var("RUNNER_DOCKER_RUNTIME")
                .ok()
                .filter(|r| !r.is_empty());
            if runtime.is_none() {
                // Plain runc shares the host kernel; gVisor (runsc) adds a
                // user-space kernel between learner code and the host.
                if std::env::var("RUNNER_ALLOW_RUNC").as_deref() != Ok("1") {
                    fail(
                        "set RUNNER_DOCKER_RUNTIME=runsc (gVisor), or RUNNER_ALLOW_RUNC=1 for development",
                    );
                }
                tracing::warn!(
                    "running jobs with Docker's default runtime (runc). Use gVisor in production."
                );
            }
            reap_all_job_containers().await;
            Sandbox::docker(
                std::env::var("RUNNER_IMAGE").unwrap_or_else(|_| "rust-runner-sandbox".to_string()),
                runtime,
            )
        }
    };

    if let Err(e) = check_sandbox(&sandbox, &limits).await {
        fail(&e);
    }

    let allowed_origins: Vec<String> = std::env::var("RUNNER_ALLOWED_ORIGINS")
        .unwrap_or_default()
        .split(',')
        .map(|o| o.trim().to_string())
        .filter(|o| !o.is_empty())
        .collect();
    if allowed_origins.is_empty() {
        tracing::warn!("RUNNER_ALLOWED_ORIGINS is not set: any website may call this runner.");
    }

    let state = Arc::new(AppState {
        sandbox,
        limits,
        slots: Semaphore::new(max_jobs),
        queue_timeout,
        allowed_origins,
    });

    // Safety net: remove any job container whose cleanup was missed.
    let watchdog = state.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(30));
        loop {
            tick.tick().await;
            watchdog.sandbox.reap_orphans().await;
        }
    });

    let addr = std::env::var("RUNNER_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .expect("bind address");
    tracing::info!("listening on {addr}");
    axum::serve(listener, app(state))
        .with_graceful_shutdown(shutdown_signal())
        .await
        .expect("server error");
}
