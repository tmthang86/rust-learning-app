use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use rust_runner::app_check::{AppCheck, HttpKeySource, KeyCache};
use rust_runner::config::{Config, SandboxChoice};
use rust_runner::sandbox::{
    Sandbox, check_sandbox, docker_image_id, docker_runtimes, docker_server_version,
    reap_all_job_containers,
};
use rust_runner::{AppState, app, health, ratelimit, telemetry};
use tokio::sync::Notify;

/// How long shutdown waits for jobs in progress before giving up. Must stay
/// below systemd's `TimeoutStopSec` (60 s).
const SHUTDOWN_DEADLINE: Duration = Duration::from_secs(45);

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

/// `runsc --version`, first line. Best effort, for the startup log.
fn runsc_version() -> Option<String> {
    let out = std::process::Command::new("runsc")
        .arg("--version")
        .output()
        .ok()?;
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()
        .map(|l| l.trim().to_string())
}

#[tokio::main]
async fn main() {
    let mut self_check_only = false;
    for arg in std::env::args().skip(1) {
        match arg.as_str() {
            // Prints before any config is read, so deploy scripts can run
            // it on a binary with no environment.
            "--version" => {
                println!("rust-runner {}", env!("CARGO_PKG_VERSION"));
                return;
            }
            "--self-check" => self_check_only = true,
            other => fail(&format!(
                "unknown argument {other:?} (supported: --version, --self-check)"
            )),
        }
    }

    let cfg = match Config::from_env() {
        Ok(cfg) => cfg,
        Err(problems) => {
            eprintln!("rust-runner: the configuration has problems, not starting:");
            for p in &problems {
                eprintln!("  - {p}");
            }
            eprintln!("See runner/README.md and runner/docs/production-design.md (section 8).");
            std::process::exit(2);
        }
    };
    telemetry::init_tracing(cfg.log_format);

    let sandbox = match &cfg.sandbox {
        SandboxChoice::Local => {
            tracing::warn!("RUNNER_SANDBOX=local runs code unsandboxed. Development only.");
            Sandbox::Local
        }
        SandboxChoice::Docker { image, runtime } => {
            if cfg.is_production() {
                match docker_runtimes().await {
                    Ok(runtimes) if runtimes.iter().any(|r| r == "runsc") => {}
                    Ok(runtimes) => fail(&format!(
                        "production needs gVisor: the Docker daemon has no `runsc` runtime (it has: {})",
                        runtimes.join(", ")
                    )),
                    Err(e) => fail(&e),
                }
            }
            if runtime.is_none() {
                tracing::warn!(
                    "running jobs with Docker's default runtime (runc). Use gVisor in production."
                );
            }
            // `--self-check` runs next to a live runner and must not touch
            // its containers.
            if !self_check_only {
                reap_all_job_containers().await;
            }
            Sandbox::docker(image.clone(), runtime.clone())
        }
    };

    if self_check_only {
        let started = Instant::now();
        match check_sandbox(&sandbox, &cfg.limits).await {
            Ok(()) => {
                println!("self-check ok in {} ms", started.elapsed().as_millis());
                return;
            }
            Err(e) => {
                eprintln!("self-check failed: {e}");
                std::process::exit(1);
            }
        }
    }

    // Warm-up: the first compile after the image is pulled can be slow.
    let warm = Instant::now();
    if let Err(e) = check_sandbox(&sandbox, &cfg.limits).await {
        fail(&e);
    }
    log_startup(&cfg, warm.elapsed()).await;

    let app_check = cfg.app_check.as_ref().map(|ac| {
        let source = HttpKeySource::new(ac.jwks_url.clone()).unwrap_or_else(|e| fail(&e));
        let cache = KeyCache::new(Arc::new(source));
        tokio::spawn(cache.clone().run_refresh_loop());
        AppCheck::new(ac, cache)
    });

    let state = Arc::new(AppState::from_config(&cfg, sandbox, app_check));
    state.health.mark_good(); // the warm-up job above

    // Safety net: remove any job container whose cleanup was missed.
    let watchdog = state.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(30));
        loop {
            tick.tick().await;
            watchdog.sandbox.reap_orphans().await;
        }
    });
    tokio::spawn(telemetry::summary_loop(state.clone()));
    tokio::spawn(ratelimit::cleanup_loop(state.clone()));
    tokio::spawn(health::idle_check_loop(state.clone()));

    let listener = tokio::net::TcpListener::bind(cfg.addr)
        .await
        .unwrap_or_else(|e| fail(&format!("cannot listen on {}: {e}", cfg.addr)));
    tracing::info!(event = "listening", addr = %cfg.addr, "listening");

    // On SIGTERM: stop taking jobs (queued and new requests get 503), let
    // running ones finish, but give up after the deadline.
    let stop = Arc::new(Notify::new());
    let server = axum::serve(
        listener,
        app(state.clone()).into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown({
        let stop = stop.clone();
        async move { stop.notified().await }
    });
    let signalled = {
        let state = state.clone();
        async move {
            shutdown_signal().await;
            state.begin_shutdown();
            stop.notify_one();
            tokio::time::sleep(SHUTDOWN_DEADLINE).await;
        }
    };
    tokio::select! {
        result = server => result.expect("server error"),
        _ = signalled => tracing::error!("shutdown took too long: exiting with jobs still running"),
    }
}

/// One `startup` event: the settings that matter and what it runs on.
async fn log_startup(cfg: &Config, warm_up: Duration) {
    let (kind, image, runtime) = match &cfg.sandbox {
        SandboxChoice::Local => ("local", String::new(), None),
        SandboxChoice::Docker { image, runtime } => ("docker", image.clone(), runtime.clone()),
    };
    let image_id = if kind == "docker" {
        docker_image_id(&image).await
    } else {
        None
    };
    tracing::info!(
        event = "startup",
        version = env!("CARGO_PKG_VERSION"),
        env = if cfg.is_production() { "production" } else { "development" },
        addr = %cfg.addr,
        sandbox = kind,
        image,
        image_id,
        runtime,
        docker = docker_server_version().await,
        runsc = runsc_version(),
        app_check = cfg.app_check.is_some(),
        max_jobs = cfg.max_jobs,
        max_queued = cfg.max_queued,
        max_inflight_per_client = cfg.max_inflight_per_client,
        memory_mb = cfg.limits.memory_mb,
        program_vmem_kb = cfg.limits.program_vmem_kb(),
        limit_ip_per_min = cfg.rate.ip.per_min,
        limit_token_per_min = cfg.rate.token.per_min,
        allowed_origins = cfg.allowed_origins.len(),
        self_check_ms = warm_up.as_millis() as u64,
        "starting"
    );
    if cfg.allowed_origins.is_empty() {
        tracing::warn!("RUNNER_ALLOWED_ORIGINS is not set: any website may call this runner.");
    }
}
