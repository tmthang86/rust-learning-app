//! Log hygiene: the request log never contains code, program output, tokens,
//! header values or client addresses.
//!
//! This is its own test file (one test, one process) on purpose: `tracing`
//! caches per-callsite interest, and a scoped subscriber installed in a
//! process where other tests' threads hit the same callsites first can miss
//! events.

mod common;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::http::StatusCode;
use common::*;
use rust_runner::AppState;
use rust_runner::client_ip::TrustedProxies;
use rust_runner::config::{BucketConfig, RateConfig};
use rust_runner::ratelimit::RateLimits;
use rust_runner::sandbox::{Limits, Sandbox};

#[derive(Clone, Default)]
struct LogBuffer(Arc<Mutex<Vec<u8>>>);

impl std::io::Write for LogBuffer {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for LogBuffer {
    type Writer = LogBuffer;
    fn make_writer(&'a self) -> LogBuffer {
        self.clone()
    }
}

#[tokio::test(flavor = "current_thread")]
async fn logs_never_contain_code_tokens_or_addresses() {
    let buffer = LogBuffer::default();
    let subscriber = tracing_subscriber::fmt()
        .with_max_level(tracing::Level::TRACE)
        .json()
        .flatten_event(true)
        .with_writer(buffer.clone())
        .finish();
    let _guard = tracing::subscriber::set_default(subscriber);

    let mut st = AppState::for_tests(
        Sandbox::Local,
        Limits {
            run_timeout: Duration::from_secs(2),
            ..Limits::default()
        },
    );
    st.app_check = Some(app_check_with_test_keys().await);
    st.proxies = TrustedProxies::parse("127.0.0.1/32").unwrap();
    st.rate = RateLimits::new(RateConfig {
        token: BucketConfig {
            per_min: 1,
            burst: 1,
            per_hour: 100,
        },
        ip: BucketConfig::OFF,
        max_keys: 50_000,
    });
    let st = Arc::new(st);

    let client_ip = "198.51.100.77";
    let code_marker = "SECRET_CODE_MARKER_8f3a";
    let token = valid_token();
    let bad_token = format!("{}tampered", token);
    let calls = |code: String, token: String| {
        run_request_with(
            &code,
            &[
                ("x-firebase-appcheck", &token),
                ("x-forwarded-for", client_ip),
                ("authorization", "Bearer SECRET_BEARER_MARKER"),
                ("user-agent", "SECRET_UA_MARKER/1.0"),
            ],
        )
    };
    // 1. runs and prints the marker; 2. rate limited; 3. a compile error that
    // echoes the marker; 4. a bad token; 5. no header at all.
    let results = [
        send(
            router(st.clone(), "127.0.0.1"),
            calls(
                format!("fn main() {{ println!(\"{code_marker}\"); }}"),
                token.clone(),
            ),
        )
        .await
        .0,
        send(
            router(st.clone(), "127.0.0.1"),
            calls(
                format!("fn main() {{ println!(\"{code_marker}\"); }}"),
                token.clone(),
            ),
        )
        .await
        .0,
        send(
            router(st.clone(), "127.0.0.1"),
            calls(
                format!("fn main() {{ let {code_marker}: i32 = \"x\"; }}"),
                valid_token(),
            ),
        )
        .await
        .0,
        send(
            router(st.clone(), "127.0.0.1"),
            calls("fn main() {}".into(), bad_token.clone()),
        )
        .await
        .0,
        send(
            router(st.clone(), "127.0.0.1"),
            run_request_with("fn main() {}", &[("x-forwarded-for", client_ip)]),
        )
        .await
        .0,
    ];
    assert_eq!(
        results,
        [
            StatusCode::OK,
            StatusCode::TOO_MANY_REQUESTS,
            StatusCode::OK,
            StatusCode::UNAUTHORIZED,
            StatusCode::UNAUTHORIZED
        ]
    );

    // /grade: a request that runs, with test code, ids, expected output and
    // a failure message that must not reach the logs. It uses another token
    // (the first one is rate limited).
    let test_marker = "SECRET_TEST_MARKER_5c1d";
    let grade_token = valid_token();
    let graded = send(
        router(st.clone(), "127.0.0.1"),
        grade_request_with(
            &format!("fn f() -> i32 {{ 1 }}\nfn main() {{ println!(\"{code_marker}\"); }}"),
            serde_json::json!([
                { "id": "secret-id-5c1d", "code": format!("check_eq!(f(), 2); let _ = \"{test_marker}\";") },
                { "id": "out", "output": test_marker },
            ]),
            &[
                ("x-firebase-appcheck", &grade_token),
                ("x-forwarded-for", client_ip),
            ],
        ),
    )
    .await;
    assert_eq!(graded.0, StatusCode::OK, "{}", graded.2);
    assert_eq!(graded.2["tests"][0]["status"], "fail");

    let logs = String::from_utf8(buffer.0.lock().unwrap().clone()).unwrap();
    let lines = logs
        .lines()
        .filter(|l| l.contains("\"run_finished\""))
        .count();
    assert_eq!(lines, 6, "one run_finished line per request:\n{logs}");
    for secret in [
        code_marker,
        test_marker,
        "secret-id-5c1d",
        "check_eq", // test code
        "f() == 2", // a failure's expression
        client_ip,
        "SECRET_BEARER_MARKER",
        "SECRET_UA_MARKER",
        "mismatched types", // compiler output
        token.as_str(),
        token.split('.').nth(1).unwrap(), // the payload alone
        token.split('.').nth(2).unwrap(), // the signature alone
        bad_token.as_str(),
    ] {
        assert!(!logs.contains(secret), "logs leak {secret:?}:\n{logs}");
    }
    // What the logs should say instead.
    for wanted in [
        "\"outcome\":\"ok\"",
        "\"outcome\":\"rate_limited\"",
        "\"outcome\":\"compile_error\"",
        "\"outcome\":\"auth_failed\"",
        "\"limiter\":\"token_short\"",
        "\"auth_error\":\"missing\"",
        "\"platform\":\"android\"",
        "\"request_id\":",
        "\"endpoint\":\"grade\"",
        "\"tests_total\":2",
        "\"tests_passed\":0",
    ] {
        assert!(logs.contains(wanted), "missing {wanted} in:\n{logs}");
    }
    assert!(logs.contains("\"client\":\""), "hashed client key expected");
}
