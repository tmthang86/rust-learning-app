mod common;

use std::sync::Arc;
use std::sync::OnceLock;
use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use rust_runner::AppState;
use rust_runner::sandbox::{Limits, Sandbox};
use serde_json::{Value, json};
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

// --- POST /grade ---

async fn post_grade(state: Arc<AppState>, code: &str, tests: Value) -> (StatusCode, Value) {
    let (status, _, body) = common::send(
        common::router(state, "127.0.0.1"),
        common::grade_request(code, tests),
    )
    .await;
    (status, body)
}

async fn grade_local(code: &str, tests: Value) -> Value {
    let (status, body) = post_grade(state(Sandbox::Local), code, tests).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body
}

/// `["pass", "fail", ...]` of a `/grade` answer, in request order.
fn statuses(out: &Value) -> Vec<String> {
    out["tests"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["status"].as_str().unwrap().to_string())
        .collect()
}

const CHECK_AGE: &str = "fn check_age(age: u32) -> Result<u32, String> {\n    if age < 18 {\n        Err(String::from(\"too young\"))\n    } else {\n        Ok(age)\n    }\n}\n\nfn main() {\n    match check_age(15) {\n        Ok(a) => println!(\"welcome, age {a}\"),\n        Err(e) => println!(\"error: {e}\"),\n    }\n}\n";

fn age_tests() -> Value {
    json!([
        { "id": "fifteen", "code": "check_eq!(check_age(15), Err(String::from(\"too young\")));" },
        { "id": "thirty", "code": "check_eq!(check_age(30), Ok(30));" },
        { "id": "boundary", "code": "check_eq!(check_age(18), Ok(18));" },
        { "id": "prints", "output": "error: too young" },
    ])
}

#[tokio::test]
async fn g1_the_solution_passes_every_test() {
    let out = grade_local(CHECK_AGE, age_tests()).await;
    assert_eq!(statuses(&out), ["pass"; 4], "{out}");
    assert_eq!(out["success"], true);
    assert_eq!(out["stage"], "run");
    assert_eq!(out["stdout"], "error: too young\n");
    assert!(
        out["compileErrorsIn"].is_null() && out["reason"].is_null(),
        "{out}"
    );
    assert_eq!(out["warnings"], "");
    assert!(out["durationMs"].is_u64());
}

#[tokio::test]
async fn g2_a_todo_starter_panics_with_not_yet_implemented() {
    let starter = CHECK_AGE.replace(
        "    if age < 18 {\n        Err(String::from(\"too young\"))\n    } else {\n        Ok(age)\n    }\n",
        "    todo!()\n",
    );
    let out = grade_local(&starter, age_tests()).await;
    assert_eq!(
        statuses(&out),
        ["panic", "panic", "panic", "panic"],
        "{out}"
    );
    let t = &out["tests"][0];
    assert!(
        t["message"]
            .as_str()
            .unwrap()
            .contains("not yet implemented"),
        "{out}"
    );
    assert_eq!(t["line"], 2);
    // Output tests fail because main panics (it calls the todo!() too).
    assert_eq!(out["success"], false);
}

#[tokio::test]
async fn g3_a_renamed_function_means_the_tests_do_not_fit() {
    let renamed = CHECK_AGE.replace("check_age", "verify_age");
    let out = grade_local(&renamed, age_tests()).await;
    assert_eq!(out["stage"], "compile", "{out}");
    assert_eq!(out["compileErrorsIn"], "tests", "{out}");
    assert_eq!(statuses(&out), ["error", "error", "error", "not_run"]);
    assert_eq!(out["tests"][0]["reason"], "tests_dont_fit");
    assert!(
        out["tests"][0]["message"]
            .as_str()
            .unwrap()
            .contains("cannot find function"),
        "{out}"
    );
    assert_eq!(out["stderr"], "");
}

/// Local jobs run in a random temp dir; Docker jobs always in /tmp. Drops
/// the directory so two jobs' compiler output can be compared.
fn without_dir(text: &str) -> String {
    text.lines()
        .map(|l| match l.find("/main.rs") {
            Some(i) => {
                let start = l[..i].rfind(' ').map_or(0, |p| p + 1);
                format!("{}{}", &l[..start], &l[i + 1..])
            }
            None => l.to_string(),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[tokio::test]
async fn g3b_compile_errors_in_the_learners_code_read_exactly_as_under_run() {
    let cases = [
        (
            "missing brace",
            "fn add(a: i32) -> i32 {\n    a + 1\n\nfn main() {}\n",
        ),
        (
            "type error",
            "fn add(a: i32) -> i32 { \"x\" }\nfn main() {}\n",
        ),
        (
            "borrow error",
            "fn add(a: i32) -> i32 { let s = String::new(); let t = s; let _u = s; let _ = t; a }\nfn main() {}\n",
        ),
        // These two pass a metadata-only check, which is why the learner-only
        // check uses --emit=mir.
        (
            "arithmetic_overflow",
            "fn add(a: i32) -> i32 { let x: u8 = 255 + 1; a + x as i32 }\nfn main() {}\n",
        ),
        (
            "unconditional_panic",
            "fn add(a: i32) -> i32 { a + [1, 2, 3][5] }\nfn main() {}\n",
        ),
    ];
    for (name, code) in cases {
        let run = run_local(code).await;
        let graded = grade_local(
            code,
            json!([{ "id": "t", "code": "check_eq!(add(1), 2);" }]),
        )
        .await;
        assert_eq!(run["stage"], "compile", "{name}");
        assert_eq!(graded["stage"], "compile", "{name}: {graded}");
        assert_eq!(graded["compileErrorsIn"], "code", "{name}: {graded}");
        assert_eq!(
            without_dir(graded["stderr"].as_str().unwrap()),
            without_dir(run["stderr"].as_str().unwrap()),
            "{name}"
        );
        assert_eq!(statuses(&graded), ["not_run"], "{name}");
    }
}

#[tokio::test]
async fn g3c_a_learners_own_cfg_test_error_is_reported_as_theirs() {
    let code = "fn add(a: i32) -> i32 { a }\nfn main() {}\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn t() { let x: i32 = \"a\"; }\n}\n";
    let out = grade_local(
        code,
        json!([{ "id": "t", "code": "check_eq!(add(1), 1);" }]),
    )
    .await;
    assert_eq!(out["compileErrorsIn"], "code", "{out}");
    assert!(
        out["stderr"].as_str().unwrap().contains("mismatched types"),
        "{out}"
    );
    assert!(out["reason"].is_null(), "{out}");
}

#[tokio::test]
async fn g3d_deny_warnings_and_forbid_unsafe() {
    let code =
        "#![deny(warnings)]\nfn id(n: i32) -> i32 { n }\nfn main() { println!(\"{}\", id(1)); }\n";
    let out = grade_local(
        code,
        json!([
            { "id": "a", "code": "check_eq!(id(1), 1);" },
            { "id": "o", "output": "1" },
            { "id": "p", "code": "let r: Result<i32, i32> = Err(1); r.unwrap();", "panics": "" },
        ]),
    )
    .await;
    assert_eq!(statuses(&out), ["pass"; 3], "{out}");

    // The documented residual: the unsafe capture code is refused.
    let forbid = "#![forbid(unsafe_code)]\nfn id(n: i32) -> i32 { n }\nfn main() {}\n";
    let out = grade_local(
        forbid,
        json!([{ "id": "cap", "code": "check_eq!(output_of(|| { id(1); }), \"\");" }]),
    )
    .await;
    assert_eq!(out["stage"], "compile", "{out}");
    assert_eq!(out["compileErrorsIn"], "tests", "{out}");
    assert_eq!(out["reason"], "harness", "{out}");
}

#[tokio::test]
async fn g4_a_test_that_never_ends_times_out_and_later_tests_do_not_run() {
    let code = "fn spin(n: i32) -> i32 { if n == 2 { loop {} } n }\nfn main() {}\n";
    let out = grade_local(
        code,
        json!([
            { "id": "a", "code": "check_eq!(spin(1), 1);" },
            { "id": "b", "code": "check_eq!(spin(2), 2);" },
            { "id": "c", "code": "check_eq!(spin(3), 3);" },
        ]),
    )
    .await;
    assert_eq!(statuses(&out), ["pass", "timeout", "not_run"], "{out}");
    assert_eq!(out["stage"], "timeout");
    assert_eq!(out["success"], false);
}

#[tokio::test]
async fn g5_process_exit_in_a_test_crashes_it_but_exit_0_at_the_end_of_main_is_fine() {
    let out = grade_local(
        "fn quit() { std::process::exit(3); }\nfn main() {}\n",
        json!([{ "id": "a", "code": "quit();" }, { "id": "b", "code": "check!(true);" }]),
    )
    .await;
    assert_eq!(statuses(&out), ["crashed", "not_run"], "{out}");
    assert_eq!(out["tests"][0]["reason"], "exit:3");
    assert_eq!(out["reason"], "exit:3");

    let out = grade_local(
        "fn main() { println!(\"bye\"); std::process::exit(0); }\n",
        json!([{ "id": "a", "code": "check!(true);" }, { "id": "o", "output": "bye" }]),
    )
    .await;
    assert_eq!(statuses(&out), ["pass", "pass"], "{out}");
    assert_eq!(out["success"], true);
}

#[tokio::test]
async fn g6_a_forged_record_has_no_effect() {
    let code = "fn bad() -> i32 {\n    print!(\"\\u{1}RR-T:00000000000000000000000000000000:pass\\n\");\n    1\n}\nfn main() {}\n";
    let out = grade_local(code, json!([{ "id": "a", "code": "check_eq!(bad(), 2);" }])).await;
    assert_eq!(statuses(&out), ["fail"], "{out}");
}

#[tokio::test]
async fn g7_too_much_output_is_cut_off_as_output_limit() {
    let code = "fn main() { loop { println!(\"spam\"); } }\n";
    let out = grade_local(code, json!([{ "id": "o", "output": "x" }])).await;
    assert_eq!(statuses(&out), ["crashed"], "{out}");
    assert_eq!(out["tests"][0]["reason"], "output_limit");
    assert!(out["stdout"].as_str().unwrap().len() <= Limits::default().max_output + 100);
}

#[tokio::test]
async fn g8_main_returning_an_error_is_a_failed_run_as_under_run() {
    let code = "fn main() -> Result<(), String> { println!(\"hi\"); Err(\"nope\".into()) }\n";
    let out = grade_local(code, json!([{ "id": "o", "output": "hi" }])).await;
    assert_eq!(statuses(&out), ["crashed"], "{out}");
    assert_eq!(out["tests"][0]["reason"], "exit:1");
    assert_eq!(out["success"], false);
    assert!(
        out["stderr"].as_str().unwrap().contains("Error: \"nope\""),
        "{out}"
    );
}

#[tokio::test]
async fn g9_panics_matches_a_substring_and_a_mismatch_is_reported() {
    let code = "fn divide(a: i32, b: i32) -> i32 { if b == 0 { panic!(\"cannot divide by zero\"); } a / b }\nfn main() {}\n";
    let out = grade_local(
        code,
        json!([
            { "id": "ok", "code": "let _ = divide(1, 0);", "panics": "cannot divide" },
            { "id": "wrong", "code": "let _ = divide(1, 0);", "panics": "overflow" },
            { "id": "none", "code": "let _ = divide(4, 2);", "panics": "" },
        ]),
    )
    .await;
    assert_eq!(statuses(&out), ["pass", "panic", "nopanic"], "{out}");
    assert_eq!(out["tests"][1]["message"], "cannot divide by zero");
    assert_eq!(out["tests"][1]["line"], 1);
}

#[tokio::test]
async fn g10_a_learners_own_failing_test_is_not_run() {
    let code = "fn main() { println!(\"ok\"); }\n#[test]\nfn mine() { panic!(\"no\"); }\n";
    let out = grade_local(code, json!([{ "id": "o", "output": "ok" }])).await;
    assert_eq!(statuses(&out), ["pass"], "{out}");
}

#[tokio::test]
async fn g11_bad_test_lists_get_400_tests_invalid() {
    let many: Vec<Value> = (0..51)
        .map(|i| json!({ "id": format!("t{i}"), "code": "check!(true);" }))
        .collect();
    let long_code = "x".repeat(5000);
    let bad = [
        json!([]),
        json!(many),
        json!([{ "id": "A", "code": "check!(true);" }]),
        json!([{ "id": "a", "code": "check!(true);" }, { "id": "a", "code": "check!(true);" }]),
        json!([{ "id": "a" }]),
        json!([{ "id": "a", "code": "x", "output": "y" }]),
        json!([{ "id": "a", "output": "y", "panics": "z" }]),
        json!([{ "id": "a", "code": long_code }]),
    ];
    for tests in bad {
        let (status, body) = post_grade(state(Sandbox::Local), "fn main() {}", tests.clone()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{tests}");
        assert_eq!(body["code"], "tests_invalid", "{body}");
        assert!(body["error"].is_string());
    }
    // Same code checks as /run.
    let t = json!([{ "id": "a", "code": "check!(true);" }]);
    let (status, body) = post_grade(state(Sandbox::Local), "  ", t.clone()).await;
    assert_eq!(
        (status, &body["code"]),
        (StatusCode::BAD_REQUEST, &json!("code_empty"))
    );
    let big = "a".repeat(rust_runner::MAX_CODE_BYTES + 10);
    let (status, body) = post_grade(state(Sandbox::Local), &big, t.clone()).await;
    assert_eq!(
        (status, &body["code"]),
        (StatusCode::PAYLOAD_TOO_LARGE, &json!("code_too_long"))
    );
    // A body past the hard limit.
    let huge = "a".repeat(rust_runner::MAX_GRADE_BODY_BYTES + 10);
    let (status, body) = post_grade(state(Sandbox::Local), &huge, t).await;
    assert_eq!(
        (status, &body["code"]),
        (StatusCode::PAYLOAD_TOO_LARGE, &json!("code_too_long"))
    );
    // Not JSON, and a missing tests field.
    let router = || common::router(state(Sandbox::Local), "127.0.0.1");
    let req = Request::post("/grade")
        .header("content-type", "application/json")
        .body(Body::from("{\"code\":\"fn main() {}\"}"))
        .unwrap();
    let (status, _, v) = common::send(router(), req).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(v["code"], "bad_request");
}

/// 20 threads at once: they work in `/run`, and must in `/grade`, where only
/// the grading thread has the big stack (8 MiB each would not fit the
/// sandbox's address-space cap).
const MANY_THREADS: &str = "use std::thread;\nfn sum(n: usize) -> usize { let hs: Vec<_> = (0..n).map(|i| thread::spawn(move || i)).collect(); hs.into_iter().map(|h| h.join().unwrap()).sum() }\nfn main() { println!(\"{}\", sum(20)); }\n";

#[tokio::test]
async fn g13b_many_threads_work_in_run_and_in_grade() {
    let run = run_local(MANY_THREADS).await;
    assert_eq!(run["stdout"], "190\n", "{run}");
    let out = grade_local(
        MANY_THREADS,
        json!([{ "id": "t", "code": "check_eq!(sum(20), 190);" }, { "id": "o", "output": "190" }]),
    )
    .await;
    assert_eq!(statuses(&out), ["pass", "pass"], "{out}");
}

#[tokio::test]
async fn g13_a_deep_recursion_works_in_run_and_in_grade() {
    let code = "fn depth(n: u64, pad: [u8; 256]) -> u64 { if n == 0 { pad[0] as u64 } else { 1 + depth(n - 1, std::hint::black_box(pad)) } }\nfn main() { println!(\"{}\", depth(20_000, [0; 256])); }\n";
    let run = run_local(code).await;
    assert_eq!(run["stdout"], "20000\n", "{run}");
    let out = grade_local(
        code,
        json!([
            { "id": "deep", "code": "check_eq!(depth(20_000, [0; 256]), 20_000);" },
            { "id": "o", "output": "20000" },
        ]),
    )
    .await;
    assert_eq!(statuses(&out), ["pass", "pass"], "{out}");
}

#[tokio::test]
async fn g14_learner_names_that_shadow_the_prelude_still_compile() {
    let code = "#![allow(dead_code)]\nenum Option { A }\nstruct String(i32);\nstruct Vec;\nstruct Box;\ntype Result<T> = std::result::Result<T, i32>;\nfn Ok() {}\nfn Err() {}\nfn Some() {}\nfn None() {}\nfn double(n: i32) -> i32 { n * 2 }\nfn main() { println!(\"{}\", double(2)); }\n";
    let out = grade_local(
        code,
        json!([{ "id": "a", "code": "check_eq!(double(2), 4);" }, { "id": "o", "output": "4" }]),
    )
    .await;
    assert_eq!(statuses(&out), ["pass", "pass"], "{out}");
}

#[tokio::test]
async fn g15_a_learner_forbid_unused_variables_with_clean_tests_passes() {
    let code = "#![forbid(unused_variables)]\nfn id(n: i32) -> i32 { n }\nfn main() { println!(\"{}\", id(1)); }\n";
    let out = grade_local(code, json!([{ "id": "a", "code": "check_eq!(id(1), 1);" }])).await;
    assert_eq!(statuses(&out), ["pass"], "{out}");
}

#[tokio::test]
async fn g16_a_panic_in_a_thread_the_learner_spawns_reaches_stderr() {
    let code =
        "fn go() { let _ = std::thread::spawn(|| panic!(\"in thread\")).join(); }\nfn main() {}\n";
    let out = grade_local(code, json!([{ "id": "a", "code": "go();" }])).await;
    assert_eq!(statuses(&out), ["pass"], "{out}");
    assert!(
        out["stderr"].as_str().unwrap().contains("in thread"),
        "{out}"
    );
}

#[tokio::test]
async fn the_harness_is_not_given_the_learners_source_to_read() {
    // The sources are deleted before the program starts.
    let code = "fn leftover(dir: &std::path::Path) -> bool { dir.join(\"main.rs\").exists() || dir.join(\"g\").exists() }\nfn main() {}\n";
    let out = grade_local(
        code,
        json!([{ "id": "a", "code": "let exe = std::env::current_exe().unwrap(); check!(!leftover(exe.parent().unwrap()));" }]),
    )
    .await;
    assert_eq!(statuses(&out), ["pass"], "{out}");
}

#[tokio::test]
async fn grade_and_run_share_one_set_of_slots() {
    let mut st = AppState::for_tests(Sandbox::Local, Limits::default());
    st.slots = Semaphore::new(0);
    st.queue_timeout = Duration::from_millis(100);
    let st = Arc::new(st);
    let (status, body) = post_grade(
        st.clone(),
        "fn main() {}",
        json!([{ "id": "a", "output": "" }]),
    )
    .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["code"], "busy");
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

/// `/grade` in the container: the main cases, the stack size, no source file
/// left for the program (D2), and `output_of` (D3, which needs dup2 to work
/// under the container's kernel interface).
#[tokio::test]
#[ignore]
async fn docker_grade_runs_the_cases() {
    let _turn = DOCKER_SUITE.lock().await;
    let grade = |code: &'static str, tests: Value| async move {
        let (status, body) = post_grade(docker_state(), code, tests).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body
    };

    // D1: G1 the solution passes.
    let out = grade(CHECK_AGE, age_tests()).await;
    assert_eq!(statuses(&out), ["pass"; 4], "{out}");
    assert_eq!(out["success"], true, "{out}");

    // G2: a todo!() starter.
    let starter = CHECK_AGE.replace(
        "    if age < 18 {\n        Err(String::from(\"too young\"))\n    } else {\n        Ok(age)\n    }\n",
        "    todo!()\n",
    );
    let starter: &'static str = Box::leak(starter.into_boxed_str());
    let out = grade(starter, age_tests()).await;
    assert_eq!(statuses(&out)[0], "panic", "{out}");
    assert!(
        out["tests"][0]["message"]
            .as_str()
            .unwrap()
            .contains("not yet implemented")
    );

    // G3: a renamed function, compile errors in the learner's code (the
    // learner-only check runs in the container too).
    let renamed: &'static str = Box::leak(
        CHECK_AGE
            .replace("check_age", "verify_age")
            .into_boxed_str(),
    );
    let out = grade(renamed, age_tests()).await;
    assert_eq!(out["compileErrorsIn"], "tests", "{out}");
    let broken = "fn add(a: i32) -> i32 { let x: u8 = 255 + 1; a + x as i32 }\nfn main() {}\n";
    let out = grade(
        broken,
        json!([{ "id": "t", "code": "check_eq!(add(1), 2);" }]),
    )
    .await;
    assert_eq!(out["compileErrorsIn"], "code", "{out}");
    assert!(
        out["stderr"]
            .as_str()
            .unwrap()
            .contains("arithmetic_overflow"),
        "{out}"
    );
    let (_, run) = post_run(docker_state(), broken).await;
    assert_eq!(
        without_dir(out["stderr"].as_str().unwrap()),
        without_dir(run["stderr"].as_str().unwrap())
    );

    // G4: an endless test.
    let spin = "fn spin(n: i32) -> i32 { if n == 2 { loop {} } n }\nfn main() {}\n";
    let out = grade(
        spin,
        json!([
            { "id": "a", "code": "check_eq!(spin(1), 1);" },
            { "id": "b", "code": "check_eq!(spin(2), 2);" },
            { "id": "c", "code": "check_eq!(spin(3), 3);" },
        ]),
    )
    .await;
    assert_eq!(statuses(&out), ["pass", "timeout", "not_run"], "{out}");

    // G13: the stack of a test is the main thread's.
    let deep = "fn depth(n: u64, pad: [u8; 256]) -> u64 { if n == 0 { pad[0] as u64 } else { 1 + depth(n - 1, std::hint::black_box(pad)) } }\nfn main() { println!(\"{}\", depth(20_000, [0; 256])); }\n";
    let out = grade(deep, json!([{ "id": "deep", "code": "check_eq!(depth(20_000, [0; 256]), 20_000);" }, { "id": "o", "output": "20000" }])).await;
    assert_eq!(statuses(&out), ["pass", "pass"], "{out}");

    // Many threads, under the sandbox's address-space cap.
    let out = grade(
        MANY_THREADS,
        json!([{ "id": "t", "code": "check_eq!(sum(20), 190);" }, { "id": "o", "output": "190" }]),
    )
    .await;
    assert_eq!(statuses(&out), ["pass", "pass"], "{out}");

    // D2: nothing of the source is left in /tmp when the program runs.
    let leftovers = "fn count() -> usize { std::fs::read_dir(\"/tmp\").unwrap().filter_map(|e| e.ok()).filter(|e| e.file_name() == \"main.rs\" || e.file_name() == \"g\").count() }\nfn main() {}\n";
    let out = grade(
        leftovers,
        json!([{ "id": "a", "code": "check_eq!(count(), 0);" }]),
    )
    .await;
    assert_eq!(statuses(&out), ["pass"], "{out}");

    // D3: output_of captures prints in the container.
    let greet = "fn greet() { println!(\"hello\"); }\nfn main() { greet(); }\n";
    let out = grade(
        greet,
        json!([
            { "id": "cap", "code": "check_eq!(output_of(|| greet()), \"hello\\n\");" },
            { "id": "o", "output": "hello" },
        ]),
    )
    .await;
    assert_eq!(statuses(&out), ["pass", "pass"], "{out}");
    assert_eq!(out["stdout"], "hello\n", "{out}");

    // The capture is bounded: a flood inside output_of fails that test (the
    // write past the limit panics) and does not fill the tmpfs.
    let flood = "fn spam() { for _ in 0..2_000_000 { println!(\"0123456789012345678901234567890123456789\"); } }\nfn main() { println!(\"done\"); }\n";
    let out = grade(
        flood,
        json!([
            { "id": "spam", "code": "output_of(|| spam());", "panics": "failed printing" },
            { "id": "o", "output": "done" },
        ]),
    )
    .await;
    assert_eq!(statuses(&out), ["pass", "pass"], "{out}");
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

/// Where the lesson JSON files are: `RUNNER_LESSONS_DIR`, else the repo's
/// `assets/content/lessons` next to this crate. Panics when neither exists
/// (a cross-built test binary on a host without the repo has no lessons:
/// set the variable, or skip the tests that read them).
fn lessons_dir() -> std::path::PathBuf {
    let dir = match std::env::var_os("RUNNER_LESSONS_DIR") {
        Some(d) => std::path::PathBuf::from(d),
        None => std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../assets/content/lessons"),
    };
    assert!(
        dir.is_dir(),
        "lessons directory {} does not exist: set RUNNER_LESSONS_DIR to assets/content/lessons",
        dir.display()
    );
    dir
}

/// A shipped lesson's `exercise.solution` and its `/grade` tests: `tests`
/// without the app-only `label`/`hidden`, or the legacy `expectedOutput` as
/// one output test.
fn lesson_solution_and_tests(id: &str) -> (String, Value) {
    let path = lessons_dir().join(format!("{id}.json"));
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read lesson {}: {e}", path.display()));
    let lesson: Value = serde_json::from_str(&text).unwrap();
    let ex = &lesson["exercise"];
    let solution = ex["solution"].as_str().unwrap().to_string();
    let tests: Value = match ex.get("tests") {
        Some(t) => Value::Array(
            t.as_array()
                .unwrap()
                .iter()
                .map(|t| {
                    let mut t = t.clone();
                    t.as_object_mut().unwrap().remove("label");
                    t.as_object_mut().unwrap().remove("hidden");
                    t
                })
                .collect(),
        ),
        None => json!([{ "id": "output", "output": ex["expectedOutput"] }]),
    };
    (solution, tests)
}

/// The lessons whose exercises can only test what a function prints, so
/// they use `output_of`: their real solutions pass every test under the
/// real sandbox (D3 on shipped content).
#[tokio::test]
#[ignore]
async fn docker_grade_output_of_lessons() {
    let _turn = DOCKER_SUITE.lock().await;
    for id in ["u3-l1", "u7-l4", "u10-l2"] {
        let (solution, tests) = lesson_solution_and_tests(id);
        let (status, out) = post_grade(docker_state(), &solution, tests.clone()).await;
        assert_eq!(status, StatusCode::OK, "{id}: {out}");
        let results = out["tests"].as_array().unwrap();
        assert_eq!(
            results.len(),
            tests.as_array().unwrap().len(),
            "{id}: {out}"
        );
        for r in results {
            assert_eq!(r["status"], "pass", "{id}: {out}");
        }
    }
}

/// Whole-job time of `/grade` against `/run` (container start included) on
/// the lessons' own solutions: the cost the design budgets at 1.5x. Prints
/// the medians; run with `cargo test --test api cost -- --ignored --nocapture`.
/// Set `COST_RUNS` for the number of rounds (default 3; the numbers in the design doc used 9).
#[tokio::test]
#[ignore]
async fn cost_grade_against_run_on_lesson_solutions() {
    let _turn = DOCKER_SUITE.lock().await;
    let rounds: usize = std::env::var("COST_RUNS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(3);
    let median = |mut v: Vec<f64>| {
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        v[v.len() / 2]
    };
    for id in ["u6-l2", "u12-l2", "u0-l1"] {
        let (solution, tests) = lesson_solution_and_tests(id);
        let (mut runs, mut grades) = (Vec::new(), Vec::new());
        for round in 0..rounds + 1 {
            let t = std::time::Instant::now();
            let (status, out) = post_run(docker_state(), &solution).await;
            assert_eq!(status, StatusCode::OK, "{out}");
            let run_s = t.elapsed().as_secs_f64();
            let t = std::time::Instant::now();
            let (status, out) = post_grade(docker_state(), &solution, tests.clone()).await;
            assert_eq!(status, StatusCode::OK, "{out}");
            let grade_s = t.elapsed().as_secs_f64();
            let passed = out["tests"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|t| t["status"] == "pass")
                .count();
            assert_eq!(passed, out["tests"].as_array().unwrap().len(), "{out}");
            if round > 0 {
                // The first round warms the image cache.
                runs.push(run_s);
                grades.push(grade_s);
            }
        }
        let (r, g) = (median(runs), median(grades));
        println!(
            "COST {id}: run {r:.3}s, grade {g:.3}s, ratio {:.2} ({} tests)",
            g / r,
            tests.as_array().unwrap().len()
        );
    }
}

// --- /grade harness version ---

#[tokio::test]
async fn harness_is_checked_before_the_tests_are_typed() {
    // A future app: harness 2 and a test field of a type this runner does
    // not know (`code` as an object). It must hear `harness_unsupported`.
    let tests = json!([{ "id": "a", "code": { "future": true } }]);
    let (status, _, body) = common::send(
        common::router(state(Sandbox::Local), "127.0.0.1"),
        common::grade_request_harness("fn main() {}", tests, json!(2)),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert_eq!(body["code"], "harness_unsupported", "{body}");
}

#[tokio::test]
async fn grade_accepts_harness_1_and_a_missing_harness() {
    // Missing: every other grade test in this file sends no `harness`.
    let (status, _, body) = common::send(
        common::router(state(Sandbox::Local), "127.0.0.1"),
        common::grade_request_harness(CHECK_AGE, age_tests(), json!(1)),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(statuses(&body).len(), age_tests().as_array().unwrap().len());
}

#[tokio::test]
async fn grade_refuses_a_harness_version_it_does_not_know() {
    for bad in [json!(0), json!(2), json!(4_000_000_000u64)] {
        let (status, _, body) = common::send(
            common::router(state(Sandbox::Local), "127.0.0.1"),
            common::grade_request_harness(CHECK_AGE, age_tests(), bad.clone()),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad}: {body}");
        assert_eq!(body["code"], "harness_unsupported", "{bad}: {body}");
        assert!(body["error"].as_str().unwrap().contains("supported: 1"));
    }
    // Not a number at all: the body is malformed, not a version problem.
    let (status, _, body) = common::send(
        common::router(state(Sandbox::Local), "127.0.0.1"),
        common::grade_request_harness(CHECK_AGE, age_tests(), json!("1")),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{body}");
    assert_eq!(body["code"], "bad_request");
}
