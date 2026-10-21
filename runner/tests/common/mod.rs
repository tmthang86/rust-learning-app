//! Helpers shared by the integration tests.
#![allow(dead_code)]

use std::net::SocketAddr;
use std::sync::Arc;

use axum::Router;
use axum::body::Body;
use axum::extract::connect_info::MockConnectInfo;
use axum::http::{HeaderMap, Request, StatusCode};
use http_body_util::BodyExt;
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode, get_current_timestamp};
use rust_runner::app_check::{AppCheck, KeyCache, StaticKeySource};
use rust_runner::config::AppCheckConfig;
use rust_runner::{AppState, app};
use serde_json::{Value, json};
use tower::ServiceExt;

pub const JWKS: &str = include_str!("../fixtures/jwks.json");
pub const KEY1: &str = include_str!("../fixtures/test-key-1.pem");
pub const KEY2: &str = include_str!("../fixtures/test-key-2.pem");
pub const PROJECT_NUMBER: &str = "123456789012";
pub const PROJECT_ID: &str = "test-project-1";
pub const APP_ID: &str = "1:123456789012:android:0123abcd";
pub const WEB_APP_ID: &str = "1:123456789012:web:4567";

pub fn router(state: Arc<AppState>, peer: &str) -> Router {
    let addr: SocketAddr = format!("{peer}:50000").parse().unwrap();
    app(state).layer(MockConnectInfo(addr))
}

pub fn run_request(code: &str) -> Request<Body> {
    Request::post("/run")
        .header("content-type", "application/json")
        .body(Body::from(json!({ "code": code }).to_string()))
        .unwrap()
}

pub fn run_request_with(code: &str, headers: &[(&str, &str)]) -> Request<Body> {
    let mut req = Request::post("/run").header("content-type", "application/json");
    for (k, v) in headers {
        req = req.header(*k, *v);
    }
    req.body(Body::from(json!({ "code": code }).to_string()))
        .unwrap()
}

/// A `POST /grade` request. `tests` is the JSON array of tests.
pub fn grade_request(code: &str, tests: Value) -> Request<Body> {
    grade_request_with(code, tests, &[])
}

pub fn grade_request_with(code: &str, tests: Value, headers: &[(&str, &str)]) -> Request<Body> {
    let mut req = Request::post("/grade").header("content-type", "application/json");
    for (k, v) in headers {
        req = req.header(*k, *v);
    }
    req.body(Body::from(
        json!({ "code": code, "tests": tests }).to_string(),
    ))
    .unwrap()
}

pub async fn send(app: Router, req: Request<Body>) -> (StatusCode, HeaderMap, Value) {
    let res = app.oneshot(req).await.unwrap();
    let status = res.status();
    let headers = res.headers().clone();
    let body = res.into_body().collect().await.unwrap().to_bytes();
    let json = serde_json::from_slice(&body).unwrap_or(Value::Null);
    (status, headers, json)
}

pub fn app_check_config() -> AppCheckConfig {
    AppCheckConfig {
        project_number: PROJECT_NUMBER.into(),
        project_id: Some(PROJECT_ID.into()),
        app_ids: vec![APP_ID.into(), WEB_APP_ID.into()],
        jwks_url: "unused".into(),
    }
}

/// An `AppCheck` with the test keys already loaded.
pub async fn app_check_with_test_keys() -> AppCheck {
    let cache = KeyCache::new(Arc::new(StaticKeySource::new(JWKS)));
    cache.refresh_now().await.unwrap();
    AppCheck::new(&app_check_config(), cache)
}

pub fn claims(sub: &str, exp_offset: i64) -> Value {
    json!({
        "iss": format!("https://firebaseappcheck.googleapis.com/{PROJECT_NUMBER}"),
        "aud": [format!("projects/{PROJECT_NUMBER}"), format!("projects/{PROJECT_ID}")],
        "sub": sub,
        "exp": get_current_timestamp() as i64 + exp_offset,
        "iat": get_current_timestamp(),
        // Makes each token string unique, like a real attestation would.
        "jti": uuid::Uuid::new_v4().to_string(),
    })
}

/// A valid token for `sub`, signed with test key 1.
pub fn token_for(sub: &str) -> String {
    let mut header = Header::new(Algorithm::RS256);
    header.kid = Some("test-1".into());
    encode(
        &header,
        &claims(sub, 3600),
        &EncodingKey::from_rsa_pem(KEY1.as_bytes()).unwrap(),
    )
    .unwrap()
}

pub fn valid_token() -> String {
    token_for(APP_ID)
}
