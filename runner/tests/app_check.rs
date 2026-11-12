//! Integration tests for the `/run` gate (App Check, rate limits), CORS, the
//! queue cap, `/health`, the JWKS fetch and log hygiene. They use the local
//! (unsandboxed) backend and static test keys.

mod common;

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::*;
use rust_runner::AppState;
use rust_runner::app_check::{AppCheck, FailingKeySource, HttpKeySource, KeyCache, KeySource};
use rust_runner::client_ip::TrustedProxies;
use rust_runner::config::{BucketConfig, RateConfig};
use rust_runner::ratelimit::RateLimits;
use rust_runner::sandbox::{Limits, Sandbox};
use tokio::sync::Semaphore;

fn limits() -> Limits {
    Limits {
        run_timeout: Duration::from_secs(2),
        ..Limits::default()
    }
}

async fn secured_state() -> AppState {
    let mut st = AppState::for_tests(Sandbox::Local, limits());
    st.app_check = Some(app_check_with_test_keys().await);
    st
}

const HELLO: &str = r#"fn main() { println!("hi"); }"#;
/// Stops at the code check: fast, and proves a request got past the gate.
const EMPTY: &str = "  ";

fn bucket(per_min: u32, burst: u32, per_hour: u32) -> BucketConfig {
    BucketConfig {
        per_min,
        burst,
        per_hour,
    }
}

fn rate(token: BucketConfig, ip: BucketConfig) -> RateLimits {
    RateLimits::new(RateConfig {
        token,
        ip,
        max_keys: 50_000,
    })
}

fn with_token(code: &str, token: &str) -> Request<Body> {
    run_request_with(code, &[("x-firebase-appcheck", token)])
}

// --- App Check ---

#[tokio::test]
async fn missing_header_is_401() {
    let st = Arc::new(secured_state().await);
    let (status, headers, body) = send(router(st, "127.0.0.1"), run_request(HELLO)).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["code"], "app_check_missing");
    assert!(body["error"].is_string());
    assert!(headers.contains_key("x-request-id"));
}

#[tokio::test]
async fn bad_tokens_are_401_with_a_generic_message() {
    let st = Arc::new(secured_state().await);
    let mut expired = claims(APP_ID, -600);
    expired["exp"] = serde_json::json!(1);
    for token in ["garbage", "a.b.c", ""] {
        let (status, _, body) =
            send(router(st.clone(), "127.0.0.1"), with_token(HELLO, token)).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "{token:?}");
        assert_eq!(body["code"], "app_check_invalid");
        assert_eq!(body["error"], "This app couldn't be verified.");
    }
    // A token signed by the wrong key looks the same to the client.
    let mut header = jsonwebtoken::Header::new(jsonwebtoken::Algorithm::RS256);
    header.kid = Some("test-1".into());
    let forged = jsonwebtoken::encode(
        &header,
        &claims(APP_ID, 3600),
        &jsonwebtoken::EncodingKey::from_rsa_pem(KEY2.as_bytes()).unwrap(),
    )
    .unwrap();
    let (status, _, body) = send(router(st, "127.0.0.1"), with_token(HELLO, &forged)).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["error"], "This app couldn't be verified.");
}

#[tokio::test]
async fn valid_token_runs_the_code() {
    let st = Arc::new(secured_state().await);
    let (status, headers, body) =
        send(router(st, "127.0.0.1"), with_token(HELLO, &valid_token())).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["stdout"], "hi\n");
    assert!(headers.contains_key("x-request-id"));
}

#[tokio::test]
async fn authorization_header_is_ignored() {
    let st = Arc::new(secured_state().await);
    let req = run_request_with(
        HELLO,
        &[
            ("x-firebase-appcheck", &valid_token()),
            ("authorization", "Bearer garbage"),
        ],
    );
    let (status, _, body) = send(router(st.clone(), "127.0.0.1"), req).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    // ... and it is no substitute for the App Check header either.
    let req = run_request_with(
        HELLO,
        &[("authorization", &format!("Bearer {}", valid_token()))],
    );
    let (status, _, body) = send(router(st, "127.0.0.1"), req).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["code"], "app_check_missing");
}

#[tokio::test]
async fn valid_token_for_an_unlisted_app_is_403() {
    let st = Arc::new(secured_state().await);
    let token = token_for("1:123456789012:ios:dead");
    let (status, _, body) = send(router(st, "127.0.0.1"), with_token(HELLO, &token)).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body["code"], "app_not_allowed");
}

#[tokio::test]
async fn no_keys_means_503_auth_unavailable() {
    let cache = KeyCache::new(Arc::new(FailingKeySource));
    let mut st = AppState::for_tests(Sandbox::Local, limits());
    st.app_check = Some(AppCheck::new(&app_check_config(), cache));
    let (status, headers, body) = send(
        router(Arc::new(st), "127.0.0.1"),
        with_token(HELLO, &valid_token()),
    )
    .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["code"], "auth_unavailable");
    assert_eq!(headers["retry-after"], "5");
}

#[tokio::test]
async fn app_check_off_ignores_the_header() {
    let st = Arc::new(AppState::for_tests(Sandbox::Local, limits()));
    let (status, _, _) = send(router(st, "127.0.0.1"), with_token(HELLO, "garbage")).await;
    assert_eq!(status, StatusCode::OK);
}

// --- rate limits ---

#[tokio::test]
async fn token_limit_gives_429_with_retry_after() {
    let mut st = secured_state().await;
    st.rate = rate(bucket(1, 1, 100), BucketConfig::OFF);
    let st = Arc::new(st);
    let a = valid_token();
    let (status, _, _) = send(router(st.clone(), "127.0.0.1"), with_token(EMPTY, &a)).await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "first request passes the gate"
    );
    let (status, headers, body) =
        send(router(st.clone(), "127.0.0.1"), with_token(EMPTY, &a)).await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(body["code"], "rate_limited");
    let secs: u64 = headers["retry-after"].to_str().unwrap().parse().unwrap();
    assert!((1..=60).contains(&secs), "{secs}");
    // Another device (another token) is not affected.
    let b = valid_token();
    assert_ne!(a, b);
    let (status, _, _) = send(router(st, "127.0.0.1"), with_token(EMPTY, &b)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn bad_tokens_do_not_use_up_a_tokens_allowance() {
    let mut st = secured_state().await;
    st.rate = rate(bucket(1, 1, 100), BucketConfig::OFF);
    let st = Arc::new(st);
    for _ in 0..3 {
        let (status, _, _) = send(
            router(st.clone(), "127.0.0.1"),
            with_token(EMPTY, "garbage"),
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
    let (status, _, _) = send(router(st, "127.0.0.1"), with_token(EMPTY, &valid_token())).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

// --- /grade goes through the same gate ---

/// A `/grade` body that stops at test validation: fast, and proves a request
/// got past the gate.
fn grade_stops_early(headers: &[(&str, &str)]) -> Request<Body> {
    grade_request_with("fn main() {}", serde_json::json!([]), headers)
}

#[tokio::test]
async fn grade_needs_app_check_like_run() {
    let st = Arc::new(secured_state().await);
    let (status, _, body) = send(router(st.clone(), "127.0.0.1"), grade_stops_early(&[])).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["code"], "app_check_missing");
    let (status, _, body) = send(
        router(st.clone(), "127.0.0.1"),
        grade_stops_early(&[("x-firebase-appcheck", "garbage")]),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["code"], "app_check_invalid");
    let token = valid_token();
    let (status, _, body) = send(
        router(st, "127.0.0.1"),
        grade_stops_early(&[("x-firebase-appcheck", &token)]),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "past the gate");
    assert_eq!(body["code"], "tests_invalid");
}

#[tokio::test]
async fn run_and_grade_drain_one_token_bucket_and_one_ip_bucket() {
    // Per token.
    let mut st = secured_state().await;
    st.rate = rate(bucket(2, 2, 100), BucketConfig::OFF);
    let st = Arc::new(st);
    let a = valid_token();
    let (s1, _, _) = send(router(st.clone(), "127.0.0.1"), with_token(EMPTY, &a)).await;
    let (s2, _, _) = send(
        router(st.clone(), "127.0.0.1"),
        grade_stops_early(&[("x-firebase-appcheck", &a)]),
    )
    .await;
    assert_eq!((s1, s2), (StatusCode::BAD_REQUEST, StatusCode::BAD_REQUEST));
    let (s3, _, body) = send(router(st.clone(), "127.0.0.1"), with_token(EMPTY, &a)).await;
    assert_eq!(
        s3,
        StatusCode::TOO_MANY_REQUESTS,
        "one bucket: run, grade, then run again"
    );
    assert_eq!(body["code"], "rate_limited");
    let (s4, headers, _) = send(
        router(st, "127.0.0.1"),
        grade_stops_early(&[("x-firebase-appcheck", &a)]),
    )
    .await;
    assert_eq!(s4, StatusCode::TOO_MANY_REQUESTS);
    assert!(headers.contains_key("retry-after"));

    // Per IP.
    let mut st = AppState::for_tests(Sandbox::Local, limits());
    st.rate = rate(BucketConfig::OFF, bucket(2, 2, 100));
    let st = Arc::new(st);
    let (a, _, _) = send(router(st.clone(), "127.0.0.1"), run_request(EMPTY)).await;
    let (b, _, _) = send(router(st.clone(), "127.0.0.1"), grade_stops_early(&[])).await;
    let (c, _, _) = send(router(st, "127.0.0.1"), grade_stops_early(&[])).await;
    assert_eq!(
        (a, b, c),
        (
            StatusCode::BAD_REQUEST,
            StatusCode::BAD_REQUEST,
            StatusCode::TOO_MANY_REQUESTS
        )
    );
}

fn xff(ip: &str) -> Request<Body> {
    run_request_with(EMPTY, &[("x-forwarded-for", ip)])
}

async fn code_of(st: &Arc<AppState>, peer: &str, req: Request<Body>) -> StatusCode {
    send(router(st.clone(), peer), req).await.0
}

#[tokio::test]
async fn ip_limits_use_forwarded_for_only_from_trusted_proxies() {
    let mut st = AppState::for_tests(Sandbox::Local, limits());
    st.rate = rate(BucketConfig::OFF, bucket(1, 1, 100));
    st.proxies = TrustedProxies::parse("127.0.0.1/32").unwrap();
    let st = Arc::new(st);

    // Trusted peer (the proxy): each forwarded client has its own bucket.
    assert_eq!(
        code_of(&st, "127.0.0.1", xff("198.51.100.1")).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        code_of(&st, "127.0.0.1", xff("198.51.100.1")).await,
        StatusCode::TOO_MANY_REQUESTS
    );
    assert_eq!(
        code_of(&st, "127.0.0.1", xff("198.51.100.2")).await,
        StatusCode::BAD_REQUEST
    );
    // A client can't pick its bucket by prepending addresses.
    assert_eq!(
        code_of(&st, "127.0.0.1", xff("6.6.6.6, 198.51.100.1")).await,
        StatusCode::TOO_MANY_REQUESTS
    );

    // Untrusted peer: the header is ignored, so spoofing doesn't help.
    assert_eq!(
        code_of(&st, "203.0.113.5", xff("1.1.1.1")).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        code_of(&st, "203.0.113.5", xff("2.2.2.2")).await,
        StatusCode::TOO_MANY_REQUESTS
    );
    // Another peer has its own bucket.
    assert_eq!(
        code_of(&st, "203.0.113.6", xff("1.1.1.1")).await,
        StatusCode::BAD_REQUEST
    );
}

#[tokio::test]
async fn ip_limit_comes_before_authentication() {
    let mut st = secured_state().await;
    st.rate = rate(BucketConfig::OFF, bucket(1, 1, 100));
    let st = Arc::new(st);
    let (status, _, _) = send(router(st.clone(), "127.0.0.1"), run_request(HELLO)).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, headers, body) = send(router(st, "127.0.0.1"), run_request(HELLO)).await;
    assert_eq!(
        status,
        StatusCode::TOO_MANY_REQUESTS,
        "not 401: IP limits count failures too"
    );
    assert_eq!(body["code"], "rate_limited");
    assert!(headers.contains_key("retry-after"));
}

#[tokio::test]
async fn health_has_no_rate_limit_and_no_auth() {
    let mut st = secured_state().await;
    st.rate = rate(BucketConfig::OFF, bucket(1, 1, 100));
    let st = Arc::new(st);
    for _ in 0..5 {
        let req = Request::get("/health").body(Body::empty()).unwrap();
        let (status, _, _) = send(router(st.clone(), "127.0.0.1"), req).await;
        assert_ne!(status, StatusCode::TOO_MANY_REQUESTS);
        assert_ne!(status, StatusCode::UNAUTHORIZED);
    }
}

// --- CORS ---

const ORIGIN: &str = "https://app.example.com";

fn cors_state() -> Arc<AppState> {
    let mut st = AppState::for_tests(Sandbox::Local, limits());
    st.allowed_origins = vec![ORIGIN.to_string()];
    Arc::new(st)
}

fn preflight(origin: &str) -> Request<Body> {
    Request::builder()
        .method("OPTIONS")
        .uri("/run")
        .header("origin", origin)
        .header("access-control-request-method", "POST")
        .header(
            "access-control-request-headers",
            "content-type,x-firebase-appcheck",
        )
        .body(Body::empty())
        .unwrap()
}

#[tokio::test]
async fn preflight_allows_the_app_check_header_for_allowed_origins() {
    let (status, headers, _) = send(router(cors_state(), "127.0.0.1"), preflight(ORIGIN)).await;
    assert!(status.is_success(), "{status}");
    assert_eq!(headers["access-control-allow-origin"], ORIGIN);
    let allowed = headers["access-control-allow-headers"]
        .to_str()
        .unwrap()
        .to_lowercase();
    assert!(allowed.contains("x-firebase-appcheck"), "{allowed}");
    assert!(allowed.contains("content-type"), "{allowed}");
    assert_eq!(headers["access-control-max-age"], "3600");
}

#[tokio::test]
async fn preflight_from_another_origin_gets_no_allow_origin() {
    let (_, headers, _) = send(
        router(cors_state(), "127.0.0.1"),
        preflight("https://evil.example"),
    )
    .await;
    assert!(
        !headers.contains_key("access-control-allow-origin"),
        "{headers:?}"
    );
}

#[tokio::test]
async fn retry_after_and_request_id_are_exposed_to_browsers() {
    let mut st = AppState::for_tests(Sandbox::Local, limits());
    st.allowed_origins = vec![ORIGIN.to_string()];
    st.rate = rate(BucketConfig::OFF, bucket(1, 1, 100));
    let st = Arc::new(st);
    let req = |()| run_request_with(EMPTY, &[("origin", ORIGIN)]);
    let _ = send(router(st.clone(), "127.0.0.1"), req(())).await;
    let (status, headers, _) = send(router(st, "127.0.0.1"), req(())).await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(
        headers["access-control-allow-origin"], ORIGIN,
        "errors carry CORS headers too"
    );
    let exposed = headers["access-control-expose-headers"]
        .to_str()
        .unwrap()
        .to_lowercase();
    assert!(exposed.contains("retry-after"), "{exposed}");
    assert!(exposed.contains("x-request-id"), "{exposed}");
}

// --- queue cap ---

const SLOW: &str =
    "fn main() { std::thread::sleep(std::time::Duration::from_millis(1500)); println!(\"slow\"); }";

async fn wait_until(what: &str, mut cond: impl FnMut() -> bool) {
    let start = Instant::now();
    while !cond() {
        assert!(
            start.elapsed() < Duration::from_secs(10),
            "timed out waiting for {what}"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[tokio::test]
async fn full_queue_answers_busy_at_once() {
    let mut st = AppState::for_tests(
        Sandbox::Local,
        Limits {
            run_timeout: Duration::from_secs(5),
            ..Limits::default()
        },
    );
    st.slots = Semaphore::new(1);
    st.max_jobs = 1;
    st.max_queued = 0;
    let st = Arc::new(st);

    let first = tokio::spawn(send(router(st.clone(), "127.0.0.1"), run_request(SLOW)));
    wait_until("the first job to take the slot", || {
        st.slots.available_permits() == 0
    })
    .await;

    let started = Instant::now();
    let (status, headers, body) = send(router(st.clone(), "127.0.0.1"), run_request(HELLO)).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["code"], "busy");
    assert_eq!(headers["retry-after"], "5");
    assert!(
        started.elapsed() < Duration::from_secs(1),
        "must not wait for the queue timeout"
    );

    let (status, _, body) = first.await.unwrap();
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(st.waiting.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn queue_holds_up_to_the_cap() {
    let mut st = AppState::for_tests(
        Sandbox::Local,
        Limits {
            run_timeout: Duration::from_secs(5),
            ..Limits::default()
        },
    );
    st.slots = Semaphore::new(1);
    st.max_jobs = 1;
    st.max_queued = 1;
    let st = Arc::new(st);

    let first = tokio::spawn(send(router(st.clone(), "127.0.0.1"), run_request(SLOW)));
    wait_until("the first job to take the slot", || {
        st.slots.available_permits() == 0
    })
    .await;
    let second = tokio::spawn(send(router(st.clone(), "127.0.0.1"), run_request(HELLO)));
    wait_until("the second request to queue", || {
        st.waiting.load(Ordering::SeqCst) == 1
    })
    .await;

    let (status, _, body) = send(router(st.clone(), "127.0.0.1"), run_request(HELLO)).await;
    assert_eq!(
        status,
        StatusCode::SERVICE_UNAVAILABLE,
        "third request: queue is full"
    );
    assert_eq!(body["code"], "busy");

    assert_eq!(first.await.unwrap().0, StatusCode::OK);
    let (status, _, body) = second.await.unwrap();
    assert_eq!(
        status,
        StatusCode::OK,
        "the queued request runs once the slot frees: {body}"
    );
    assert_eq!(st.waiting.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn shutdown_turns_requests_away() {
    let st = Arc::new(AppState::for_tests(Sandbox::Local, limits()));
    st.begin_shutdown();
    let (status, _, body) = send(router(st, "127.0.0.1"), run_request(HELLO)).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["code"], "shutting_down");
}

// --- health ---

fn health_request() -> Request<Body> {
    Request::get("/health").body(Body::empty()).unwrap()
}

#[tokio::test]
async fn health_is_unhealthy_until_a_good_job_then_ok() {
    let st = Arc::new(AppState::for_tests(Sandbox::Local, limits()));
    let (status, headers, body) = send(router(st.clone(), "127.0.0.1"), health_request()).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["status"], "unhealthy");
    assert!(body["lastGoodJobSecsAgo"].is_null());
    assert_eq!(headers["cache-control"], "no-store");

    let (status, _, _) = send(router(st.clone(), "127.0.0.1"), run_request(HELLO)).await;
    assert_eq!(status, StatusCode::OK);

    let (status, headers, body) = send(router(st, "127.0.0.1"), health_request()).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["status"], "ok");
    assert_eq!(headers["cache-control"], "no-store");
    for key in [
        "lastGoodJobSecsAgo",
        "keysReady",
        "diskFreeMb",
        "runs",
        "uptimeSecs",
        "version",
    ] {
        assert!(body.get(key).is_some(), "missing {key}: {body}");
    }
    for key in [
        "ok",
        "compileError",
        "timeout",
        "memLimit",
        "rateLimited",
        "busy",
        "internal",
    ] {
        assert!(
            body["runs"].get(key).is_some(),
            "missing runs.{key}: {body}"
        );
    }
    assert_eq!(body["runs"]["ok"], 1);
    assert_eq!(body["keysReady"], true);
    assert_eq!(body["version"], env!("CARGO_PKG_VERSION"));
}

#[tokio::test]
async fn a_compile_error_is_proof_of_life_but_a_timeout_is_not() {
    let st = Arc::new(AppState::for_tests(
        Sandbox::Local,
        Limits {
            compile_timeout: Duration::from_secs(2),
            run_timeout: Duration::from_secs(2),
            job_timeout: Duration::from_secs(10),
            ..Limits::default()
        },
    ));
    let endless = "#![allow(long_running_const_eval)]\nconst X: u64 = { let mut i = 0u64; loop { i = i.wrapping_add(1); } };\nfn main() { println!(\"{}\", X); }";
    let (status, _, body) = send(router(st.clone(), "127.0.0.1"), run_request(endless)).await;
    assert_eq!(
        (status, body["stage"].as_str()),
        (StatusCode::OK, Some("timeout"))
    );
    assert_eq!(
        send(router(st.clone(), "127.0.0.1"), health_request())
            .await
            .0,
        StatusCode::SERVICE_UNAVAILABLE
    );

    let (_, _, body) = send(
        router(st.clone(), "127.0.0.1"),
        run_request("fn main() { let x: i32 = \"no\"; }"),
    )
    .await;
    assert_eq!(body["stage"], "compile");
    let (status, _, body) = send(router(st, "127.0.0.1"), health_request()).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["runs"]["compileError"], 1);
    assert_eq!(body["runs"]["timeout"], 1);
}

#[tokio::test]
async fn health_needs_the_app_check_keys_when_required() {
    let cache = KeyCache::new(Arc::new(FailingKeySource));
    let mut st = AppState::for_tests(Sandbox::Local, limits());
    st.app_check = Some(AppCheck::new(&app_check_config(), cache));
    st.health.mark_good();
    let (status, _, body) = send(router(Arc::new(st), "127.0.0.1"), health_request()).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["keysReady"], false);
    assert_eq!(body["status"], "unhealthy");
}

#[tokio::test]
async fn health_counts_rejections() {
    let mut st = secured_state().await;
    st.health.mark_good();
    st.rate = rate(bucket(1, 1, 100), BucketConfig::OFF);
    let st = Arc::new(st);
    let token = valid_token();
    let _ = send(router(st.clone(), "127.0.0.1"), with_token(EMPTY, &token)).await;
    let _ = send(router(st.clone(), "127.0.0.1"), with_token(EMPTY, &token)).await;
    let (status, _, body) = send(router(st, "127.0.0.1"), health_request()).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["runs"]["rateLimited"], 1);
}

// --- the JWKS over HTTP ---

#[derive(Clone)]
struct JwksServer {
    hits: Arc<AtomicUsize>,
}

async fn serve_jwks(
    cache_control: &'static str,
    content_type: &'static str,
    status: u16,
) -> (String, JwksServer) {
    use axum::Router;
    use axum::routing::get;
    let server = JwksServer {
        hits: Arc::new(AtomicUsize::new(0)),
    };
    let hits = server.hits.clone();
    let app = Router::new().route(
        "/jwks",
        get(move || {
            let hits = hits.clone();
            async move {
                hits.fetch_add(1, Ordering::SeqCst);
                (
                    StatusCode::from_u16(status).unwrap(),
                    [
                        ("cache-control", cache_control),
                        ("content-type", content_type),
                    ],
                    JWKS,
                )
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/jwks", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (url, server)
}

#[tokio::test]
async fn jwks_over_http_is_parsed_and_max_age_honoured() {
    // The body is JSON whatever the Content-Type says.
    let (url, server) = serve_jwks("public, max-age=300", "text/plain", 200).await;
    let source = HttpKeySource::new(url).unwrap();
    let fetched = source.fetch().await.unwrap();
    assert_eq!(fetched.max_age, Some(Duration::from_secs(300)));
    let mut kids: Vec<_> = fetched.keys.keys().cloned().collect();
    kids.sort();
    assert_eq!(kids, ["test-1", "test-2"]);
    assert_eq!(server.hits.load(Ordering::SeqCst), 1);

    // Through the cache: the refresh delay follows max-age (clamped, minus the margin).
    let (url, _) = serve_jwks(
        "public, max-age=21600",
        "application/json; charset=UTF-8",
        200,
    )
    .await;
    let cache = KeyCache::new(Arc::new(HttpKeySource::new(url).unwrap()));
    let delay = cache.refresh_now().await.unwrap();
    assert_eq!(delay, Duration::from_secs(21600 - 300));
    assert!(cache.ready());
}

/// Serves one raw HTTP response and reports how many body bytes it managed to
/// send. `chunked` streams 64 KiB chunks until the client hangs up; otherwise
/// it announces a huge Content-Length and sends nothing.
async fn serve_oversized(chunked: bool) -> (String, tokio::task::JoinHandle<usize>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/jwks", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        let (mut sock, _) = listener.accept().await.unwrap();
        let mut buf = [0u8; 2048];
        let _ = sock.read(&mut buf).await;
        let head = if chunked {
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ntransfer-encoding: chunked\r\n\r\n"
        } else {
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 50000000\r\n\r\n"
        };
        sock.write_all(head.as_bytes()).await.unwrap();
        if !chunked {
            // Hold the connection open: only the header can reject this.
            tokio::time::sleep(Duration::from_secs(20)).await;
            return 0;
        }
        let chunk = format!("{:x}\r\n{}\r\n", 65536, "a".repeat(65536));
        let mut sent = 0;
        // 64 MiB is far beyond the 1 MiB cap; a capped reader hangs up long before.
        while sent < 64 * 1024 * 1024 {
            if sock.write_all(chunk.as_bytes()).await.is_err() {
                break;
            }
            sent += 65536;
        }
        sent
    });
    (url, task)
}

#[tokio::test]
async fn oversized_jwks_is_rejected_while_reading() {
    // Announced size: rejected from the header, without waiting for a body.
    let (url, _server) = serve_oversized(false).await;
    let started = std::time::Instant::now();
    let err = HttpKeySource::new(url)
        .unwrap()
        .fetch()
        .await
        .err()
        .expect("error");
    assert!(err.contains("unreasonably large"), "{err}");
    assert!(started.elapsed() < Duration::from_secs(5));

    // No announced size: reading stops at the cap and the server sees the hang-up.
    let (url, server) = serve_oversized(true).await;
    let err = HttpKeySource::new(url)
        .unwrap()
        .fetch()
        .await
        .err()
        .expect("error");
    assert!(err.contains("unreasonably large"), "{err}");
    let sent = tokio::time::timeout(Duration::from_secs(10), server)
        .await
        .expect("server should see the client hang up")
        .unwrap();
    assert!(sent < 32 * 1024 * 1024, "client kept reading: {sent} bytes");
}

#[tokio::test]
async fn jwks_errors_are_reported() {
    let (url, _) = serve_jwks("no-store", "application/json", 500).await;
    let err = HttpKeySource::new(url)
        .unwrap()
        .fetch()
        .await
        .err()
        .expect("error");
    assert!(err.contains("500"), "{err}");
    let err = HttpKeySource::new("http://127.0.0.1:1/jwks")
        .unwrap()
        .fetch()
        .await
        .err()
        .expect("error");
    assert!(err.contains("failed"), "{err}");
}

#[tokio::test]
async fn tokens_verify_against_keys_fetched_over_http() {
    let (url, _) = serve_jwks("public, max-age=3600", "application/json", 200).await;
    let cache = KeyCache::new(Arc::new(HttpKeySource::new(url).unwrap()));
    cache.refresh_now().await.unwrap();
    let mut st = AppState::for_tests(Sandbox::Local, limits());
    st.app_check = Some(AppCheck::new(&app_check_config(), cache));
    let (status, _, body) = send(
        router(Arc::new(st), "127.0.0.1"),
        with_token(HELLO, &valid_token()),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

#[tokio::test]
async fn an_ipv6_client_is_noted_once_and_still_served() {
    use std::sync::atomic::Ordering;
    let st = Arc::new(AppState::for_tests(Sandbox::Local, limits()));
    // IPv4: nothing to note.
    let (status, _, _) = send(router(st.clone(), "127.0.0.1"), run_request(EMPTY)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(!st.ipv6_logged.load(Ordering::Relaxed));
    // IPv6 peer: served as usual, flag set.
    let (status, _, _) = send(router(st.clone(), "[2001:db8::1]"), run_request(EMPTY)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(st.ipv6_logged.load(Ordering::Relaxed));
}

// --- One running-or-queued request per client ---

/// Waits until `n` requests are queued for a slot.
async fn wait_for_waiting(st: &AppState, n: usize) {
    for _ in 0..200 {
        if st.waiting.load(Ordering::SeqCst) == n {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("expected {n} waiting requests");
}

/// A state whose job slots are taken, so an admitted request queues.
fn full_state(mut st: AppState, cap: usize) -> Arc<AppState> {
    st.slots = Semaphore::new(0);
    st.queue_timeout = Duration::from_secs(10);
    st.inflight = rust_runner::inflight::InFlight::new(cap);
    Arc::new(st)
}

#[tokio::test]
async fn a_second_request_from_one_token_gets_429_while_the_first_waits() {
    let st = full_state(secured_state().await, 1);
    let token = valid_token();
    let first = tokio::spawn({
        let (st, token) = (st.clone(), token.clone());
        async move { send(router(st, "198.51.100.1"), with_token(HELLO, &token)).await }
    });
    wait_for_waiting(&st, 1).await;

    // Same token from another IP: the token cap says no, at once.
    let started = Instant::now();
    let (status, headers, body) = send(
        router(st.clone(), "198.51.100.2"),
        with_token(HELLO, &token),
    )
    .await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS, "{body}");
    assert_eq!(body["code"], "client_busy");
    assert_eq!(headers["retry-after"], "2");
    assert!(started.elapsed() < Duration::from_secs(2), "must not queue");
    assert_eq!(st.waiting.load(Ordering::SeqCst), 1, "only the first waits");

    // The same IP is refused too, whatever the token.
    let (status, _, body) = send(
        router(st.clone(), "198.51.100.1"),
        with_token(HELLO, &token),
    )
    .await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS, "{body}");

    // A slot frees up: the first request finishes and gives its place back.
    st.slots.add_permits(1);
    let (status, _, body) = first.await.unwrap();
    assert_eq!(status, StatusCode::OK, "{body}");
    let (status, _, body) = send(router(st, "198.51.100.2"), with_token(HELLO, &token)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

#[tokio::test]
async fn learners_with_different_tokens_can_share_one_ip() {
    // Two verified tokens behind one address (a carrier NAT): both queue.
    let mut st = secured_state().await;
    st.slots = Semaphore::new(0);
    st.queue_timeout = Duration::from_secs(10);
    st.inflight = rust_runner::inflight::InFlight::with_verified_ip_cap(1, 2);
    let st = Arc::new(st);
    let (t1, t2) = (token_for(APP_ID), token_for(WEB_APP_ID));
    let spawn_run = |token: String| {
        let st = st.clone();
        tokio::spawn(
            async move { send(router(st, "198.51.100.1"), with_token(HELLO, &token)).await },
        )
    };
    let first = spawn_run(t1.clone());
    wait_for_waiting(&st, 1).await;
    let second = spawn_run(t2.clone());
    wait_for_waiting(&st, 2).await;
    // Each token holds one place, even from another address...
    let (status, _, body) = send(router(st.clone(), "198.51.100.2"), with_token(HELLO, &t1)).await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS, "{body}");
    assert_eq!(body["code"], "client_busy");
    // ...and the address is full for verified requests (checked by the IP
    // cap before the token, so a repeated token shows the IP limit).
    let (status, _, body) = send(router(st.clone(), "198.51.100.1"), with_token(HELLO, &t1)).await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS, "{body}");
    assert_eq!(body["code"], "client_busy");
    st.slots.add_permits(2);
    assert_eq!(first.await.unwrap().0, StatusCode::OK);
    assert_eq!(second.await.unwrap().0, StatusCode::OK);
}

#[tokio::test]
async fn the_ip_cap_works_without_app_check_and_lets_other_ips_through() {
    let st = full_state(AppState::for_tests(Sandbox::Local, limits()), 1);
    let first = tokio::spawn({
        let st = st.clone();
        async move { send(router(st, "198.51.100.1"), run_request(HELLO)).await }
    });
    wait_for_waiting(&st, 1).await;
    let (status, _, body) = send(router(st.clone(), "198.51.100.1"), run_request(HELLO)).await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS, "{body}");
    assert_eq!(body["code"], "client_busy");
    // Another client is not affected: it queues behind the first.
    let second = tokio::spawn({
        let st = st.clone();
        async move { send(router(st, "198.51.100.9"), run_request(HELLO)).await }
    });
    wait_for_waiting(&st, 2).await;
    st.slots.add_permits(2);
    assert_eq!(first.await.unwrap().0, StatusCode::OK);
    assert_eq!(second.await.unwrap().0, StatusCode::OK);
}

#[tokio::test]
async fn a_client_that_gives_up_while_queued_gives_its_place_back() {
    let st = full_state(AppState::for_tests(Sandbox::Local, limits()), 1);
    let first = tokio::spawn({
        let st = st.clone();
        async move { send(router(st, "198.51.100.1"), run_request(HELLO)).await }
    });
    wait_for_waiting(&st, 1).await;
    first.abort();
    let _ = first.await;
    wait_for_waiting(&st, 0).await;
    assert_eq!(
        st.inflight.active_ips(),
        0,
        "the dropped request left a place held"
    );
    st.slots.add_permits(1);
    let (status, _, _) = send(router(st, "198.51.100.1"), run_request(HELLO)).await;
    assert_eq!(status, StatusCode::OK);
}
