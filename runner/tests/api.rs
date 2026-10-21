mod common;

use std::sync::Arc;
use std::sync::OnceLock;
use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use rust_runner::AppState;
use rust_runner::sandbox::{Limits, Sandbox};
use serde_json::Value;
use tokio::sync::Semaphore;

fn state(sandbox: Sandbox) -> Arc<AppState> {
    Arc::new(AppState::for_tests(
        sandbox,
        Limits {
            run_timeout: Duration::from_secs(2),
            ..Limits::default()
        },
    ))
}

async fn post_run(state: Arc<AppState>, code: &str) -> (StatusCode, Value) {
    let (status, _, body) = common::send(
        common::router(state, "127.0.0.1"),
        common::run_request(code),
    )
    .await;
    (status, body)
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
async fn cpu_limit_signal_counts_as_timeout() {
    // The kernel's CPU-time limit sends SIGXCPU; a program killed by it must
    // be reported as a timeout, not a plain failure. The sleep is shorter
    // than the run timeout, so only the signal can make this a timeout.
    let code = r#"fn main() {
    let pid = std::process::id().to_string();
    std::process::Command::new("kill").args(["-XCPU", &pid]).status().unwrap();
    std::thread::sleep(std::time::Duration::from_secs(1));
}"#;
    let out = run_local(code).await;
    assert_eq!(out["stage"], "timeout", "{out}");
    assert_eq!(out["success"], false);
}

const ENDLESS_COMPILE: &str = "#![allow(long_running_const_eval)]\nconst X: u64 = { let mut i = 0u64; loop { i = i.wrapping_add(1); } };\nfn main() { println!(\"{}\", X); }";

/// A compile stopped by the timeout must read as a plain message to the
/// learner, with none of bash's job-control text
/// (`job: line 6: 4 Killed timeout --signal=KILL ... rustc ...`).
fn assert_compile_timeout_is_clean(out: &Value) {
    assert_eq!(out["stage"], "timeout", "{out}");
    assert_eq!(out["success"], false, "{out}");
    let stderr = out["stderr"].as_str().unwrap();
    assert!(stderr.contains("Compiling was stopped"), "{out}");
    for leak in ["Killed", "line ", "timeout --signal", "job:"] {
        assert!(!stderr.contains(leak), "{leak:?} leaked: {out}");
    }
}

fn short_compile_limits() -> Limits {
    Limits {
        compile_timeout: Duration::from_secs(2),
        run_timeout: Duration::from_secs(2),
        job_timeout: Duration::from_secs(10),
        ..Limits::default()
    }
}

#[tokio::test]
async fn endless_compile_is_stopped() {
    let mut st = AppState::for_tests(Sandbox::Local, short_compile_limits());
    st.slots = Semaphore::new(1);
    st.queue_timeout = Duration::from_secs(5);
    let st = Arc::new(st);
    let (status, out) = post_run(st, ENDLESS_COMPILE).await;
    assert_eq!(status, StatusCode::OK, "{out}");
    assert_compile_timeout_is_clean(&out);
}

#[tokio::test]
async fn bad_requests_get_json_errors() {
    let router = || common::router(state(Sandbox::Local), "127.0.0.1");
    let req = Request::post("/run")
        .header("content-type", "application/json")
        .body(Body::from("{not json"))
        .unwrap();
    let (status, headers, v) = common::send(router(), req).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(v["error"].is_string());
    assert_eq!(v["code"], "bad_request");
    assert!(headers.contains_key("x-request-id"));

    // Wrong content type and a body that isn't the expected shape.
    let req = Request::post("/run")
        .header("content-type", "text/plain")
        .body(Body::from("{}"))
        .unwrap();
    let (status, _, v) = common::send(router(), req).await;
    assert_eq!(status, StatusCode::UNSUPPORTED_MEDIA_TYPE);
    assert_eq!(v["code"], "bad_request");
    let req = Request::post("/run")
        .header("content-type", "application/json")
        .body(Body::from("{\"nope\":1}"))
        .unwrap();
    let (status, _, v) = common::send(router(), req).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(v["code"], "bad_request");

    let big = "a".repeat(rust_runner::MAX_CODE_BYTES + 4096);
    let (status, _, v) = common::send(router(), common::run_request(&big)).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
    assert!(v["error"].is_string());
    assert_eq!(v["code"], "code_too_long");

    // A body past the hard limit is also "too long".
    let huge = "a".repeat(2 * rust_runner::MAX_CODE_BYTES + 4096);
    let (status, _, v) = common::send(router(), common::run_request(&huge)).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(v["code"], "code_too_long");
}

#[tokio::test]
async fn busy_runner_answers_503() {
    let mut st = AppState::for_tests(Sandbox::Local, Limits::default());
    st.slots = Semaphore::new(0);
    st.queue_timeout = Duration::from_millis(200);
    let (status, headers, body) = common::send(
        common::router(Arc::new(st), "127.0.0.1"),
        common::run_request("fn main() {}"),
    )
    .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(headers["retry-after"], "5");
    assert_eq!(body["code"], "busy");
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
    let (status, body) = post_run(state(Sandbox::Local), "   ").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["code"], "code_empty");
}

#[tokio::test]
async fn memory_cap_reaches_the_program_but_not_the_compiler() {
    // `ulimit -v` applies to the program only: this allocation is above the
    // 320 MB cap and must fail cleanly, in a script that compiled fine.
    let code = r#"fn main() {
        let v: Vec<u8> = Vec::with_capacity(400 << 20);
        println!("allocated {}", v.capacity());
    }"#;
    let out = run_local(code).await;
    assert_eq!(out["success"], false, "{out}");
    assert_eq!(out["stage"], "run", "{out}");
    assert!(
        out["stderr"].as_str().unwrap().contains("too much memory"),
        "{out}"
    );
    // Well below the cap still works.
    let ok =
        run_local("fn main() { let v = vec![1u8; 100 << 20]; println!(\"{}\", v.len()); }").await;
    assert_eq!(ok["success"], true, "{ok}");
}

#[tokio::test]
async fn program_cannot_print_the_markers_to_fake_a_stage() {
    let out = run_local(
        r#"fn main() { print!("\u{1}RR-COMPILE\n\u{1}RR-RUN\nfake"); std::process::exit(3); }"#,
    )
    .await;
    assert_eq!(out["success"], false, "{out}");
    assert_eq!(out["stage"], "run", "{out}");
    assert!(out["stdout"].as_str().unwrap().contains("fake"), "{out}");
}

// --- Docker tests (ignored by default) ---
//
// They need Docker and the sandbox image (`docker build -t rust-runner-sandbox
// -f sandbox.Dockerfile .`). Settings, all optional:
//   RUNNER_IMAGE                    image to use (default rust-runner-sandbox)
//   RUNNER_DOCKER_RUNTIME           e.g. runsc
//   RUNNER_TEST_CONTAINER_PREFIX    name prefix of every container these tests start
//                                   (default rr-test-<random>-), so a script can check
//                                   for leftovers of this run only

fn test_prefix() -> &'static str {
    static PREFIX: OnceLock<String> = OnceLock::new();
    PREFIX.get_or_init(|| {
        std::env::var("RUNNER_TEST_CONTAINER_PREFIX").unwrap_or_else(|_| {
            let id = uuid::Uuid::new_v4().simple().to_string();
            format!("rr-test-{}-", &id[..8])
        })
    })
}

/// A Docker sandbox whose containers are named `<test prefix><extra>...`.
fn docker_named(extra: &str) -> Sandbox {
    Sandbox::docker_with_prefix(
        std::env::var("RUNNER_IMAGE").unwrap_or_else(|_| "rust-runner-sandbox".to_string()),
        std::env::var("RUNNER_DOCKER_RUNTIME")
            .ok()
            .filter(|r| !r.is_empty()),
        format!("{}{extra}", test_prefix()),
    )
}

fn docker() -> Sandbox {
    docker_named("")
}

/// The Docker tests are heavy (a 120 MB tmpfs fill, a rustc that eats memory,
/// 500 fork attempts) and some assert on timing, so they take turns instead of
/// competing for the host's CPU when `cargo test` runs them in parallel.
static DOCKER_SUITE: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Docker states use the default limits (512 MB, 128 MB tmpfs) with a short run timeout.
fn docker_state() -> Arc<AppState> {
    state(docker())
}

fn assert_memory_stop(out: &Value) {
    assert_eq!(out["success"], false, "{out}");
    assert_ne!(
        out["stage"], "timeout",
        "memory stop was reported as a timeout: {out}"
    );
    assert!(
        out["stderr"].as_str().unwrap().contains("too much memory"),
        "{out}"
    );
}

#[tokio::test]
#[ignore]
async fn docker_compile_timeout_shows_no_shell_noise() {
    let _turn = DOCKER_SUITE.lock().await;
    let st = Arc::new(AppState::for_tests(docker(), short_compile_limits()));
    let (status, out) = post_run(st, ENDLESS_COMPILE).await;
    assert_eq!(status, StatusCode::OK, "{out}");
    assert_compile_timeout_is_clean(&out);
}

#[tokio::test]
#[ignore]
async fn docker_sandbox_runs_and_blocks_network() {
    let _turn = DOCKER_SUITE.lock().await;
    let (_, out) = post_run(docker_state(), r#"fn main() { println!("hi"); }"#).await;
    assert_eq!(out["stdout"], "hi\n", "{out}");

    let net = r#"fn main() {
        let r = std::net::TcpStream::connect("1.1.1.1:80");
        println!("{}", if r.is_ok() { "connected" } else { "blocked" });
    }"#;
    let (_, out) = post_run(docker_state(), net).await;
    assert_eq!(out["stdout"], "blocked\n", "{out}");

    let write = r#"fn main() {
        let r = std::fs::write("/etc/pwned", "x");
        println!("{}", if r.is_ok() { "wrote" } else { "denied" });
    }"#;
    let (_, out) = post_run(docker_state(), write).await;
    assert_eq!(out["stdout"], "denied\n", "{out}");

    // Under gVisor the cgroup OOM kill is nondeterministic; the program's
    // address-space cap makes this a clean "too much memory" either way.
    let hog = r#"fn main() {
        let mut v: Vec<Vec<u8>> = Vec::new();
        loop { v.push(vec![1u8; 64 << 20]); }
    }"#;
    let (status, out) = post_run(docker_state(), hog).await;
    assert_eq!(status, StatusCode::OK, "{out}");
    assert_memory_stop(&out);

    let forks = r#"fn main() {
        let mut ok = 0;
        for _ in 0..500 {
            if std::process::Command::new("sleep").arg("3").spawn().is_ok() { ok += 1; }
        }
        println!("{ok}");
    }"#;
    // Spawning is slow under gVisor (500 attempts take over 2 s), so this case
    // gets a longer run timeout than the others: it checks the process limit,
    // not speed.
    let patient = Arc::new(AppState::for_tests(
        docker(),
        Limits {
            run_timeout: Duration::from_secs(10),
            job_timeout: Duration::from_secs(30),
            ..Limits::default()
        },
    ));
    let (status, out) = post_run(patient, forks).await;
    assert_eq!(status, StatusCode::OK, "{out}");
    match out["stdout"].as_str().unwrap().trim().parse::<u32>() {
        Ok(spawned) => assert!(spawned < 100, "process limit not enforced: {out}"),
        // Under gVisor, hitting the pids limit sometimes makes the sandbox
        // kill the whole container (exit code 2, no output; reproducible with
        // plain `docker run --runtime runsc --pids-limit 64`). The bomb is
        // contained either way; what must never happen is 100+ processes.
        Err(_) => {
            assert_eq!(out["success"], false, "no count and no failure: {out}");
            assert_eq!(out["stage"], "run", "{out}");
            assert_eq!(out["stdout"], "", "a failed bomb must print nothing: {out}");
        }
    }

    // Writing past the in-container pipes to PID 1's stdout must still be capped on the host.
    let bypass = r#"use std::io::Write;
    fn main() {
        let mut f = std::fs::OpenOptions::new().write(true).open("/proc/1/fd/1")
            .or_else(|_| std::fs::OpenOptions::new().write(true).open("/dev/stdout")).unwrap();
        let line = [b'x'; 1024];
        loop { let _ = f.write_all(&line); }
    }"#;
    let (status, out) = post_run(docker_state(), bypass).await;
    assert_eq!(status, StatusCode::OK, "{out}");
    assert!(
        out["stdout"].as_str().unwrap().len() <= Limits::default().max_output + 100,
        "{out}"
    );

    // Freezing the in-container timer must not extend the run past the host timer.
    // The image has no /bin/kill, so use the bash builtin.
    let freeze = r#"fn main() {
        let ppid = std::os::unix::process::parent_id();
        let cmd = format!("kill -STOP {ppid}");
        let ok = std::process::Command::new("bash").args(["-c", &cmd]).status().unwrap().success();
        assert!(ok, "could not freeze the timer");
        loop {}
    }"#;
    let started = std::time::Instant::now();
    let (_, out) = post_run(docker_state(), freeze).await;
    assert_eq!(out["stage"], "timeout", "{out}");
    let took = started.elapsed();
    assert!(
        took >= Duration::from_secs(3) && took < Duration::from_secs(15),
        "{took:?} {out}"
    );

    // A client that disconnects mid-job must not leave a container running.
    // This sandbox has its own name prefix, so other tests' jobs don't count.
    let sandbox = docker_named("cancel-");
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

/// A full tmpfs counts toward the sandbox's memory but not the program's
/// address space; the program cap leaves room for both. The OOM was
/// nondeterministic under gVisor, so this runs five times in a row.
#[tokio::test]
#[ignore]
async fn tmpfs_full_then_allocate() {
    let _turn = DOCKER_SUITE.lock().await;
    let fill_mb = Limits::default().tmpfs_mb - 8;
    let code = format!(
        r#"use std::io::Write;
fn main() {{
    let chunk = vec![7u8; 1 << 20];
    let mut f = std::fs::File::create("/tmp/fill").expect("create /tmp/fill");
    for _ in 0..{fill_mb} {{ f.write_all(&chunk).expect("write to tmpfs"); }}
    f.sync_all().ok();
    let mut v: Vec<Vec<u8>> = Vec::new();
    loop {{ v.push(vec![1u8; 16 << 20]); }}
}}"#
    );
    // Use the production run limit (5 s), not the suite's 2 s: on slow CI
    // hosts touching ~300 MB of pages can take over 2 s by itself.
    let limits = Limits::default();
    for attempt in 1..=5 {
        let (status, out) = post_run(
            Arc::new(AppState::for_tests(docker(), limits.clone())),
            &code,
        )
        .await;
        assert_eq!(status, StatusCode::OK, "attempt {attempt}: {out}");
        assert_eq!(out["stage"], "run", "attempt {attempt}: {out}");
        assert_memory_stop(&out);
    }
}

/// The program can't dump core: a limit of 0 is ignored when the host pipes
/// dumps to a helper such as apport, so the container gets 1 byte (hard).
#[tokio::test]
#[ignore]
async fn core_dumps_are_off_even_for_piped_core_patterns() {
    let _turn = DOCKER_SUITE.lock().await;
    let code = r#"fn main() {
    let limits = std::fs::read_to_string("/proc/self/limits").unwrap();
    let line = limits.lines().find(|l| l.starts_with("Max core file size")).unwrap();
    println!("{}", line.split_whitespace().collect::<Vec<_>>().join(" "));
}"#;
    let (status, out) = post_run(docker_state(), code).await;
    assert_eq!(status, StatusCode::OK, "{out}");
    assert_eq!(out["stdout"], "Max core file size 1 1 bytes\n", "{out}");
}

/// rustc itself running out of memory (or time) is the learner's problem,
/// never a server error.
#[tokio::test]
#[ignore]
async fn rustc_oom_is_a_learner_error() {
    let _turn = DOCKER_SUITE.lock().await;
    let code = r#"#![allow(long_running_const_eval)]
const BIG: [u8; 1 << 31] = [1; 1 << 31];
fn main() { println!("{}", BIG[7]); }"#;
    let limits = Limits {
        compile_timeout: Duration::from_secs(20),
        job_timeout: Duration::from_secs(40),
        ..Limits::default()
    };
    let mut st = AppState::for_tests(docker(), limits);
    st.queue_timeout = Duration::from_secs(10);
    let (status, out) = post_run(Arc::new(st), code).await;
    assert_eq!(status, StatusCode::OK, "{out}");
    let stage = out["stage"].as_str().unwrap();
    assert!(stage == "compile" || stage == "timeout", "{out}");
    assert_eq!(out["success"], false, "{out}");
}
