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
        limits: Limits { run_timeout: Duration::from_secs(2), ..Limits::default() },
        slots: Semaphore::new(2),
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
    let docker = || Sandbox::Docker { image: "rust-runner-sandbox".into() };

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
    assert!(out["stderr"].as_str().unwrap().contains("too much memory"), "{out}");

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
}
