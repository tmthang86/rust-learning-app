//! Error responses of the HTTP API.
//!
//! Every error is `{"error": "<message>", "code": "<code>"}`. `error` stays
//! for older app builds; new clients match on `code`.

use axum::Json;
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde_json::json;

use crate::telemetry::{Outcome, RunInfo};

#[derive(Debug, Clone)]
pub struct ApiError {
    pub status: StatusCode,
    pub code: &'static str,
    pub message: String,
    /// Seconds for the `Retry-After` header.
    pub retry_after: Option<u64>,
    /// What the request log line should say about this failure. Boxed to
    /// keep `Result<_, ApiError>` small (clippy::result_large_err).
    pub info: Box<RunInfo>,
}

impl ApiError {
    pub fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        let outcome = match code {
            "rate_limited" | "client_busy" => Outcome::RateLimited,
            "app_check_missing" | "app_check_invalid" | "app_not_allowed" | "auth_unavailable" => {
                Outcome::AuthFailed
            }
            "busy" | "shutting_down" => Outcome::Busy,
            "internal" => Outcome::Internal,
            _ => Outcome::BadRequest,
        };
        Self {
            status,
            code,
            message: message.into(),
            retry_after: None,
            info: Box::new(RunInfo {
                outcome: Some(outcome),
                ..RunInfo::default()
            }),
        }
    }

    pub fn retry_after(mut self, secs: u64) -> Self {
        self.retry_after = Some(secs);
        self
    }

    pub fn with_info(mut self, edit: impl FnOnce(&mut RunInfo)) -> Self {
        edit(&mut self.info);
        self
    }

    pub fn code_empty() -> Self {
        Self::new(StatusCode::BAD_REQUEST, "code_empty", "code is empty")
    }

    pub fn code_too_long() -> Self {
        Self::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "code_too_long",
            "code is too long",
        )
    }

    pub fn bad_request(status: StatusCode, message: impl Into<String>) -> Self {
        Self::new(status, "bad_request", message)
    }

    pub fn app_check_missing() -> Self {
        Self::new(
            StatusCode::UNAUTHORIZED,
            "app_check_missing",
            "This app couldn't be verified.",
        )
    }

    pub fn app_check_invalid() -> Self {
        Self::new(
            StatusCode::UNAUTHORIZED,
            "app_check_invalid",
            "This app couldn't be verified.",
        )
    }

    pub fn app_not_allowed() -> Self {
        Self::new(
            StatusCode::FORBIDDEN,
            "app_not_allowed",
            "This version of the app can't run code.",
        )
    }

    pub fn auth_unavailable() -> Self {
        Self::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "auth_unavailable",
            "The runner can't verify apps right now, try again shortly",
        )
        .retry_after(5)
    }

    pub fn rate_limited(retry_after: u64, limiter: &'static str) -> Self {
        Self::new(
            StatusCode::TOO_MANY_REQUESTS,
            "rate_limited",
            "too many requests, slow down",
        )
        .retry_after(retry_after.max(1))
        .with_info(|i| i.limiter = Some(limiter))
    }

    /// The client already has a job running or queued (see `inflight`).
    pub fn client_busy(scope: crate::inflight::Scope) -> Self {
        Self::new(
            StatusCode::TOO_MANY_REQUESTS,
            "client_busy",
            "a run from this app is still in progress, wait for it to finish",
        )
        .retry_after(crate::inflight::RETRY_AFTER_SECS)
        .with_info(|i| i.limiter = Some(scope.as_str()))
    }

    pub fn harness_unsupported(sent: u64) -> Self {
        Self::new(
            StatusCode::BAD_REQUEST,
            "harness_unsupported",
            format!(
                "harness version {sent} is not supported (supported: {})",
                crate::SUPPORTED_HARNESS
                    .iter()
                    .map(u32::to_string)
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        )
    }

    pub fn busy() -> Self {
        Self::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "busy",
            "runner is busy, try again shortly",
        )
        .retry_after(5)
    }

    pub fn shutting_down() -> Self {
        Self::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "shutting_down",
            "runner is shutting down",
        )
    }

    pub fn internal() -> Self {
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal",
            "could not run the code",
        )
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut res = (
            self.status,
            Json(json!({ "error": self.message, "code": self.code })),
        )
            .into_response();
        if let Some(secs) = self.retry_after {
            res.headers_mut()
                .insert(header::RETRY_AFTER, HeaderValue::from(secs));
        }
        res.extensions_mut().insert(*self.info);
        res
    }
}
