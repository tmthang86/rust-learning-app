//! HTTP service that compiles and runs Rust code for the Learn Rust app.

pub mod sandbox;

use std::sync::Arc;

use axum::extract::{DefaultBodyLimit, State};
use axum::http::{Method, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::json;
use tokio::sync::Semaphore;
use tower_http::cors::{Any, CorsLayer};

use sandbox::{Limits, Sandbox};

/// Largest source file accepted, in bytes.
pub const MAX_CODE_BYTES: usize = 64 * 1024;

pub struct AppState {
    pub sandbox: Sandbox,
    pub limits: Limits,
    /// Caps how many jobs run at once; extra requests wait their turn.
    pub slots: Semaphore,
}

#[derive(Deserialize)]
pub struct RunRequest {
    pub code: String,
}

pub fn app(state: Arc<AppState>) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods([Method::GET, Method::POST])
        .allow_headers([header::CONTENT_TYPE]);

    Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/run", post(run))
        .layer(DefaultBodyLimit::max(MAX_CODE_BYTES + 1024))
        .layer(cors)
        .with_state(state)
}

async fn run(State(state): State<Arc<AppState>>, Json(req): Json<RunRequest>) -> Response {
    if req.code.trim().is_empty() {
        return error(StatusCode::BAD_REQUEST, "code is empty");
    }
    if req.code.len() > MAX_CODE_BYTES {
        return error(StatusCode::PAYLOAD_TOO_LARGE, "code is too long");
    }

    let Ok(_permit) = state.slots.acquire().await else {
        return error(StatusCode::SERVICE_UNAVAILABLE, "runner is shutting down");
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
