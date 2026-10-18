use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use rust_runner::sandbox::{Limits, Sandbox};
use rust_runner::{AppState, app};
use serde_json::{Value, json};
use tokio::sync::Semaphore;
use tower::ServiceExt;

fn state(sandbox: Sandbox) -> Arc<AppState> {
    Arc::new(AppState {
        sandbox,
        limits: Limits {
            run_timeout: Duration::from_secs(2),
            ..Limits::default()
        },
        slots: Semaphore::new(2),
        queue_timeout: Duration::from_secs(10),
        allowed_origins: Vec::new(),
    })
}

async fn post_run(state: Arc<AppState>, code: &str) -> (StatusCode, Value) {
    let req = Request::post("/run")
        .header("content-type", "application/json")
        .body(Body::from(json!({ "code": code }).to_string()))
        .unwrap();
    let res = app(state).oneshot(req).await.unwrap();
    let status = res.status();
    let body = res.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&body).unwrap())
}

async fn run_local(code: &str) -> Value {
    let (status, body) = post_run(state(Sandbox::Local), code).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body
}

#[tokio::test]
async fn hello_world_runs() {
    let out = run_local(r#"fn main() { println!("Hello, Rust!"); }"#).await;
    assert_eq!(out["success"], true);
    assert_eq!(out["stage"], "run");
    assert_eq!(out["stdout"], "Hello, Rust!\n");
}

#[tokio::test]
async fn compile_error_is_reported() {
    let out = run_local("fn main() { let x: i32 = \"no\"; }").await;
    assert_eq!(out["success"], false);
    assert_eq!(out["stage"], "compile");
    assert!(out["stderr"].as_str().unwrap().contains("mismatched types"));
}

#[tokio::test]
async fn panic_is_a_failed_run() {
    let out = run_local(r#"fn main() { panic!("boom"); }"#).await;
    assert_eq!(out["success"], false);
    assert_eq!(out["stage"], "run");
    assert!(out["stderr"].as_str().unwrap().contains("boom"));
}

#[tokio::test]
async fn infinite_loop_times_out() {
    let out = run_local("fn main() { loop {} }").await;
    assert_eq!(out["success"], false);
    assert_eq!(out["stage"], "timeout");
}

#[tokio::test]
async fn endless_output_is_capped() {
    let out = run_local(r#"fn main() { loop { println!("spam"); } }"#).await;
    let stdout = out["stdout"].as_str().unwrap();
    assert!(stdout.len() <= Limits::default().max_output + 100);
    assert!(stdout.ends_with("[output truncated]"));
    assert!(out["stderr"].as_str().unwrap().contains("too much output"));
}

#[tokio::test]
async fn warnings_are_separate_from_program_output() {
    let out =
        run_local(r#"fn main() { let unused = 1; eprintln!("to stderr"); println!("ok"); }"#).await;
    assert_eq!(out["success"], true);
    assert_eq!(out["stdout"], "ok\n");
    assert_eq!(out["stderr"], "to stderr\n");
    assert!(
        out["warnings"]
            .as_str()
            .unwrap()
            .contains("unused variable"),
        "{out}"
    );
}

#[tokio::test]
async fn overflow_panics_like_a_debug_build() {
    let out = run_local(
        "fn main() { let mut x: u8 = 250; for _ in 0..10 { x += std::hint::black_box(1); } println!(\"{x}\"); }",
    )
    .await;
    assert_eq!(out["success"], false, "{out}");
    assert!(
        out["stderr"].as_str().unwrap().contains("overflow"),
        "{out}"
    );
}

#[tokio::test]
async fn faked_exit_codes_do_not_change_the_stage() {
    let out = run_local("fn main() { std::process::exit(201); }").await;
    assert_eq!(out["stage"], "run", "{out}");
    assert_eq!(out["success"], false);
}

#[tokio::test]
async fn endless_compile_is_stopped() {
    let st = Arc::new(AppState {
        sandbox: Sandbox::Local,
        limits: Limits {
            compile_timeout: Duration::from_secs(2),
            run_timeout: Duration::from_secs(2),
            job_timeout: Duration::from_secs(10),
            ..Limits::default()
        },
        slots: Semaphore::new(1),
        queue_timeout: Duration::from_secs(5),
        allowed_origins: Vec::new(),
    });
    let code = "#![allow(long_running_const_eval)]\nconst X: u64 = { let mut i = 0u64; loop { i = i.wrapping_add(1); } };\nfn main() { println!(\"{}\", X); }";
    let (status, out) = post_run(st, code).await;
    assert_eq!(status, StatusCode::OK, "{out}");
    assert_eq!(out["stage"], "timeout", "{out}");
}

#[tokio::test]
async fn bad_requests_get_json_errors() {
    let req = Request::post("/run")
        .header("content-type", "application/json")
        .body(Body::from("{not json"))
        .unwrap();
    let res = app(state(Sandbox::Local)).oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    let body = res.into_body().collect().await.unwrap().to_bytes();
    let v: Value = serde_json::from_slice(&body).unwrap();
    assert!(v["error"].is_string());

    let big = "a".repeat(rust_runner::MAX_CODE_BYTES + 4096);
    let req = Request::post("/run")
        .header("content-type", "application/json")
        .body(Body::from(json!({ "code": big }).to_string()))
        .unwrap();
    let res = app(state(Sandbox::Local)).oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::PAYLOAD_TOO_LARGE);
    let body = res.into_body().collect().await.unwrap().to_bytes();
    assert!(serde_json::from_slice::<Value>(&body).unwrap()["error"].is_string());
}

#[tokio::test]
async fn busy_runner_answers_503() {
    let st = Arc::new(AppState {
        sandbox: Sandbox::Local,
        limits: Limits::default(),
        slots: Semaphore::new(0),
        queue_timeout: Duration::from_millis(200),
        allowed_origins: Vec::new(),
    });
    let req = Request::post("/run")
        .header("content-type", "application/json")
        .body(Body::from(json!({ "code": "fn main() {}" }).to_string()))
        .unwrap();
    let res = app(st).oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(res.headers()["retry-after"], "5");
}

#[tokio::test]
async fn many_warnings_still_run() {
    let mut code = String::from("fn main() {\n");
    for i in 0..2500 {
        code.push_str(&format!("    let v{i} = {i};\n"));
    }
    code.push_str("    println!(\"ran\");\n}\n");
    let out = run_local(&code).await;
    assert_eq!(out["success"], true, "{}", out["stderr"]);
    assert_eq!(out["stdout"], "ran\n");
    assert!(
        out["warnings"]
            .as_str()
            .unwrap()
            .ends_with("[output truncated]")
    );
}

#[tokio::test]
async fn stopping_the_timer_does_not_extend_the_run() {
    // The program freezes its own `timeout` supervisor, then spins.
    let code = r#"fn main() {
        let ppid = std::os::unix::process::parent_id();
        let _ = std::process::Command::new("kill").args(["-STOP", &ppid.to_string()]).status();
        loop {}
    }"#;
    let started = std::time::Instant::now();
    let out = run_local(code).await;
    assert_eq!(out["success"], false, "{out}");
    assert_eq!(out["stage"], "timeout", "{out}");
    assert!(
        started.elapsed() < Duration::from_secs(12),
        "ran until the job timeout: {out}"
    );
}

#[test]
fn bad_limits_are_rejected() {
    assert!(Limits::default().validate().is_ok());
    let zero = Limits {
        run_timeout: Duration::ZERO,
        ..Limits::default()
    };
    assert!(zero.validate().is_err());
    let short = Limits {
        job_timeout: Duration::from_secs(5),
        ..Limits::default()
    };
    assert!(short.validate().is_err());
}

#[tokio::test]
async fn empty_code_is_rejected() {
    let (status, _) = post_run(state(Sandbox::Local), "   ").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

/// Needs Docker and the sandbox image: `docker build -t rust-runner-sandbox -f sandbox.Dockerfile .`
#[tokio::test]
#[ignore]
async fn docker_sandbox_runs_and_blocks_network() {
    let docker = || {
        Sandbox::docker(
            "rust-runner-sandbox",
            std::env::var("RUNNER_DOCKER_RUNTIME").ok(),
        )
    };

    let (_, out) = post_run(state(docker()), r#"fn main() { println!("hi"); }"#).await;
    assert_eq!(out["stdout"], "hi\n", "{out}");

    let net = r#"fn main() {
        let r = std::net::TcpStream::connect("1.1.1.1:80");
        println!("{}", if r.is_ok() { "connected" } else { "blocked" });
    }"#;
    let (_, out) = post_run(state(docker()), net).await;
    assert_eq!(out["stdout"], "blocked\n", "{out}");

    let write = r#"fn main() {
        let r = std::fs::write("/etc/pwned", "x");
        println!("{}", if r.is_ok() { "wrote" } else { "denied" });
    }"#;
    let (_, out) = post_run(state(docker()), write).await;
    assert_eq!(out["stdout"], "denied\n", "{out}");

    let hog = r#"fn main() {
        let mut v: Vec<Vec<u8>> = Vec::new();
        loop { v.push(vec![1u8; 64 << 20]); }
    }"#;
    let (_, out) = post_run(state(docker()), hog).await;
    assert_eq!(out["success"], false, "{out}");
    assert!(
        out["stderr"].as_str().unwrap().contains("too much memory"),
        "{out}"
    );

    let forks = r#"fn main() {
        let mut ok = 0;
        for _ in 0..500 {
            if std::process::Command::new("sleep").arg("3").spawn().is_ok() { ok += 1; }
        }
        println!("{ok}");
    }"#;
    let (_, out) = post_run(state(docker()), forks).await;
    let spawned: u32 = out["stdout"].as_str().unwrap().trim().parse().unwrap();
    assert!(spawned < 100, "process limit not enforced: {out}");

    // Writing past the in-container pipes to PID 1's stdout must still be capped on the host.
    let bypass = r#"use std::io::Write;
    fn main() {
        let mut f = std::fs::OpenOptions::new().write(true).open("/proc/1/fd/1")
            .or_else(|_| std::fs::OpenOptions::new().write(true).open("/dev/stdout")).unwrap();
        let line = [b'x'; 1024];
        loop { let _ = f.write_all(&line); }
    }"#;
    let (status, out) = post_run(state(docker()), bypass).await;
    assert_eq!(status, StatusCode::OK, "{out}");
    assert!(
        out["stdout"].as_str().unwrap().len() <= Limits::default().max_output + 100,
        "{out}"
    );

    // Freezing the in-container timer must not extend the run past the host timer.
    let freeze = r#"fn main() {
        let ppid = std::os::unix::process::parent_id();
        let _ = std::process::Command::new("kill").args(["-STOP", &ppid.to_string()]).status();
        loop {}
    }"#;
    let started = std::time::Instant::now();
    let (_, out) = post_run(state(docker()), freeze).await;
    assert_eq!(out["stage"], "timeout", "{out}");
    assert!(started.elapsed() < Duration::from_secs(15), "{out}");

    // A client that disconnects mid-job must not leave a container running.
    let sandbox = docker();
    let limits = Limits::default();
    let job = sandbox.run("fn main() { loop {} }", &limits);
    let _ = tokio::time::timeout(Duration::from_secs(3), job).await; // dropped: client went away
    tokio::time::sleep(Duration::from_secs(3)).await;
    let filter = format!("name=^{}", sandbox.container_prefix().unwrap());
    let ps = std::process::Command::new("docker")
        .args(["ps", "-aq", "--filter", &filter])
        .output()
        .unwrap();
    assert!(
        String::from_utf8_lossy(&ps.stdout).trim().is_empty(),
        "container leaked after cancel"
    );
}
