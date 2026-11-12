//! The gate in front of `/run`.
//!
//! In order: the client IP and its buckets (before any authentication), App
//! Check verification, then the per-token buckets. It also writes the one
//! `run_finished` log line per request and counts outcomes.
//!
//! Every rejection is a JSON [`ApiError`]; the specific reason for an
//! authentication failure goes only to the log.

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use axum::extract::{ConnectInfo, Request, State};
use axum::http::{HeaderValue, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};

use crate::AppState;
use crate::app_check::AuthError;
use crate::client_ip::{IpSource, client_ip};
use crate::errors::ApiError;
use crate::inflight;
use crate::telemetry::{Outcome, RunInfo};

/// The request header carrying the App Check token.
pub const APP_CHECK_HEADER: &str = "x-firebase-appcheck";

/// Who is calling, put in the request extensions for the handler.
#[derive(Debug, Clone)]
pub struct Caller {
    /// The verified Firebase app ID, when App Check is on.
    pub app_id: Option<String>,
    /// `android`, `ios`, `web` or `none`.
    pub platform: &'static str,
    /// HMAC of the token, the per-token limiter's key.
    pub token_key: Option<[u8; 32]>,
}

/// The request's ID, also sent back as `X-Request-Id`.
#[derive(Debug, Clone)]
pub struct RequestId(pub String);

/// Outermost layer: gives every response (CORS preflights included) an ID.
pub async fn request_id(mut req: Request, next: Next) -> Response {
    let id = uuid::Uuid::new_v4().simple().to_string();
    req.extensions_mut().insert(RequestId(id.clone()));
    let mut res = next.run(req).await;
    if let Ok(value) = HeaderValue::from_str(&id) {
        res.headers_mut().insert("x-request-id", value);
    }
    res
}

pub async fn gate(
    State(state): State<Arc<AppState>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    mut req: Request,
    next: Next,
) -> Response {
    let started = Instant::now();
    let request_id = req
        .extensions()
        .get::<RequestId>()
        .map(|r| r.0.clone())
        .unwrap_or_default();
    let peer = peer.ip();
    let (ip, source) = client_ip(peer, req.headers(), &state.proxies);
    if source == IpSource::PeerFallback {
        tracing::warn!(
            event = "no_forwarded_for",
            "trusted proxy sent no usable X-Forwarded-For; keying by the proxy address"
        );
    }
    if first_ipv6(&state.ipv6_logged, ip) {
        // The VM has no IPv6, so this is unexpected. Limiters key it by the
        // full address; /64 grouping is future work. Once per process, and
        // without the address (logs never hold client addresses).
        tracing::warn!(
            event = "ipv6_client",
            "an IPv6 client address was seen; rate limits key it by the full address"
        );
    }
    let client = state.telemetry.hasher.short(ip.to_string().as_bytes());

    // Read the header now: the request body isn't `Sync`, so the request
    // can't be borrowed across an await.
    let token = req
        .headers()
        .get(APP_CHECK_HEADER)
        .map(|v| v.to_str().map(str::to_string).ok());
    let (response, platform) = match admit(&state, token, ip).await {
        Ok((caller, place)) => {
            let platform = caller.platform;
            req.extensions_mut().insert(caller);
            let response = next.run(req).await;
            // The place is held until the answer exists, then given back.
            drop(place);
            (response, platform)
        }
        Err(e) => (e.into_response(), "none"),
    };
    finish(&state, response, &request_id, platform, &client, started)
}

/// True the first time an IPv6 client address is seen (IPv4-mapped addresses
/// were already folded to IPv4 by `client_ip`).
fn first_ipv6(logged: &AtomicBool, ip: IpAddr) -> bool {
    ip.is_ipv6() && !logged.swap(true, Ordering::Relaxed)
}

/// Steps 1-4: IP buckets, App Check, token buckets, per-client in-flight
/// cap. The returned guard holds the client's place until it is dropped.
///
/// `token` is the App Check header: absent, present but not text (`None`
/// inside), or the token.
async fn admit(
    state: &AppState,
    token: Option<Option<String>>,
    ip: IpAddr,
) -> Result<(Caller, inflight::Guard), ApiError> {
    state
        .rate
        .check_ip(ip)
        .map_err(|r| ApiError::rate_limited(r.retry_after, r.limiter))?;

    let Some(app_check) = &state.app_check else {
        let place = state
            .inflight
            .try_acquire(ip, None)
            .map_err(ApiError::client_busy)?;
        return Ok((
            Caller {
                app_id: None,
                platform: "none",
                token_key: None,
            },
            place,
        ));
    };
    let token = token
        .ok_or_else(|| ApiError::app_check_missing().with_info(|i| i.auth_error = Some("missing")))?
        .ok_or_else(|| {
            ApiError::app_check_invalid().with_info(|i| i.auth_error = Some("malformed"))
        })?;
    let verified = app_check.verify(&token).await.map_err(|e| {
        let reason = e.reason();
        match e {
            AuthError::Invalid(_) => ApiError::app_check_invalid(),
            AuthError::NotAllowed => ApiError::app_not_allowed(),
            AuthError::Unavailable => ApiError::auth_unavailable(),
        }
        .with_info(|i| i.auth_error = Some(reason))
    })?;

    let key = state.telemetry.hasher.hash(token.as_bytes());
    state
        .rate
        .check_token(&key)
        .map_err(|r| ApiError::rate_limited(r.retry_after, r.limiter))?;
    let place = state
        .inflight
        .try_acquire(ip, Some(key))
        .map_err(ApiError::client_busy)?;
    Ok((
        Caller {
            app_id: Some(verified.app_id),
            platform: verified.platform,
            token_key: Some(key),
        },
        place,
    ))
}

/// Counts the outcome and writes the `run_finished` line.
fn finish(
    state: &AppState,
    response: Response,
    request_id: &str,
    platform: &str,
    client: &str,
    started: Instant,
) -> Response {
    let status = response.status();
    let info = response
        .extensions()
        .get::<RunInfo>()
        .cloned()
        .unwrap_or_default();
    let outcome = info.outcome.unwrap_or(match status {
        StatusCode::REQUEST_TIMEOUT => Outcome::Timeout,
        s if s.is_success() => Outcome::Ok,
        s if s.is_client_error() => Outcome::BadRequest,
        _ => Outcome::Internal,
    });
    let duration_ms = started.elapsed().as_millis() as u64;
    state.telemetry.record(outcome, duration_ms, info.queue_ms);

    macro_rules! log {
        ($level:ident) => {
            tracing::$level!(
                event = "run_finished",
                request_id,
                outcome = outcome.as_str(),
                stage = info.stage,
                status = status.as_u16(),
                queue_ms = info.queue_ms,
                duration_ms,
                code_bytes = info.code_bytes,
                stdout_bytes = info.stdout_bytes,
                stderr_bytes = info.stderr_bytes,
                truncated = info.truncated,
                endpoint = info.endpoint,
                tests_total = info.tests_total,
                tests_passed = info.tests_passed,
                platform,
                limiter = info.limiter,
                auth_error = info.auth_error,
                client,
                "run finished"
            )
        };
    }
    if outcome == Outcome::Internal {
        log!(error);
    } else {
        log!(info);
    }
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ipv6_is_flagged_once() {
        let flag = AtomicBool::new(false);
        let v4: IpAddr = "198.51.100.7".parse().unwrap();
        let v6: IpAddr = "2001:db8::1".parse().unwrap();
        assert!(!first_ipv6(&flag, v4));
        assert!(first_ipv6(&flag, v6));
        assert!(!first_ipv6(&flag, v6));
        assert!(!first_ipv6(&flag, "2001:db8::2".parse().unwrap()));
    }
}
