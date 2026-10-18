//! HTTP service that compiles and runs Rust code for the Learn Rust app.

pub mod sandbox;

use std::sync::Arc;
use std::time::Duration;

use axum::extract::rejection::JsonRejection;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::{HeaderValue, Method, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::json;
use tokio::sync::Semaphore;
use tower_http::cors::{AllowOrigin, CorsLayer};
use tower_http::timeout::TimeoutLayer;
use tower_http::trace::TraceLayer;

use sandbox::{Limits, Sandbox};

/// Largest source file accepted, in bytes.
pub const MAX_CODE_BYTES: usize = 64 * 1024;

pub struct AppState {
    pub sandbox: Sandbox,
    pub limits: Limits,
    /// Caps how many jobs run at once; extra requests wait their turn.
    pub slots: Semaphore,
    /// How long a request may wait for a free slot before getting a 503.
    pub queue_timeout: Duration,
    /// Web origins allowed to call the API from a browser. Empty allows any
    /// origin, which is only meant for local development.
    pub allowed_origins: Vec<String>,
}

#[derive(Deserialize)]
pub struct RunRequest {
    pub code: String,
}

pub fn app(state: Arc<AppState>) -> Router {
    let origins = if state.allowed_origins.is_empty() {
        AllowOrigin::any()
    } else {
        AllowOrigin::list(
            state
                .allowed_origins
                .iter()
                .filter_map(|o| HeaderValue::from_str(o).ok()),
        )
    };
    let cors = CorsLayer::new()
        .allow_origin(origins)
        .allow_methods([Method::GET, Method::POST])
        .allow_headers([header::CONTENT_TYPE]);
    // Upper bound for a whole request: waiting for a slot plus running the job.
    let request_timeout = state.queue_timeout + state.limits.job_timeout + Duration::from_secs(5);

    Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/run", post(run))
        .layer(DefaultBodyLimit::max(MAX_CODE_BYTES + 1024))
        .layer(TimeoutLayer::with_status_code(
            StatusCode::REQUEST_TIMEOUT,
            request_timeout,
        ))
        .layer(cors)
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn run(
    State(state): State<Arc<AppState>>,
    payload: Result<Json<RunRequest>, JsonRejection>,
) -> Response {
    let req = match payload {
        Ok(Json(req)) => req,
        Err(rejection) => return error(rejection.status(), &rejection.body_text()),
    };
    if req.code.trim().is_empty() {
        return error(StatusCode::BAD_REQUEST, "code is empty");
    }
    if req.code.len() > MAX_CODE_BYTES {
        return error(StatusCode::PAYLOAD_TOO_LARGE, "code is too long");
    }

    let permit = tokio::time::timeout(state.queue_timeout, state.slots.acquire()).await;
    let _permit = match permit {
        Ok(Ok(permit)) => permit,
        Ok(Err(_)) => return error(StatusCode::SERVICE_UNAVAILABLE, "runner is shutting down"),
        Err(_) => {
            let mut res = error(
                StatusCode::SERVICE_UNAVAILABLE,
                "runner is busy, try again shortly",
            );
            res.headers_mut()
                .insert(header::RETRY_AFTER, HeaderValue::from_static("5"));
            return res;
        }
    };

    match state.sandbox.run(&req.code, &state.limits).await {
        Ok(output) => Json(output).into_response(),
        Err(e) => {
            tracing::error!("sandbox failed: {e}");
            error(StatusCode::INTERNAL_SERVER_ERROR, "could not run the code")
        }
    }
}

fn error(status: StatusCode, message: &str) -> Response {
    (status, Json(json!({ "error": message }))).into_response()
}
