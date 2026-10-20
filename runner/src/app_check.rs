//! Firebase App Check token verification.
//!
//! The app sends an App Check token in the `X-Firebase-AppCheck` header. It
//! is a JWT signed (RS256) by Google. We check it against the public keys
//! at `https://firebaseappcheck.googleapis.com/v1/jwks` (cached), the
//! issuer and audience of our Firebase project, the expiry, and the app ID
//! in `sub` against an allowlist.
//!
//! This makes abuse more expensive (an attacker needs a genuine attested
//! device or browser, re-attested about hourly). It is not a hard gate; the
//! rate limits and the fixed capacity bound what gets through.

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, RwLock};
use std::time::Duration;

use jsonwebtoken::jwk::Jwk;
use jsonwebtoken::{Algorithm, DecodingKey, Validation, decode, decode_header, errors::ErrorKind};
use serde::Deserialize;
use tokio::sync::Mutex;
use tokio::time::Instant;

use crate::config::AppCheckConfig;

/// Longest token accepted, in bytes. Real tokens are around 1 KB.
pub const MAX_TOKEN_BYTES: usize = 4096;
/// Keys are cached for the response's `max-age`, clamped to this range.
const MIN_TTL: Duration = Duration::from_secs(5 * 60);
const MAX_TTL: Duration = Duration::from_secs(6 * 3600);
/// Used when the response has no usable `max-age`.
const DEFAULT_TTL: Duration = Duration::from_secs(3600);
/// Keys are refreshed this long before they expire.
const REFRESH_BEFORE_EXPIRY: Duration = Duration::from_secs(5 * 60);
/// Never refresh more often than this, whatever the TTL.
const MIN_REFRESH_GAP: Duration = Duration::from_secs(60);
/// An unknown `kid` may trigger a refresh at most this often.
const MISS_REFRESH_GAP: Duration = Duration::from_secs(60);
/// How long a request waits for another request's refresh.
const MISS_WAIT: Duration = Duration::from_secs(5);
/// Without a successful refresh for this long, the keys are dropped and
/// `/run` answers 503.
const MAX_KEY_AGE: Duration = Duration::from_secs(24 * 3600);
const FETCH_TIMEOUT: Duration = Duration::from_secs(10);
/// A JWKS document is a few KB; refuse anything absurd.
const MAX_JWKS_BYTES: usize = 1024 * 1024;

type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// What one fetch of the key set returned.
pub struct FetchedKeys {
    pub keys: HashMap<String, DecodingKey>,
    /// From the response's `Cache-Control: max-age`.
    pub max_age: Option<Duration>,
}

/// Where the public keys come from. The real one is HTTP; tests use a fake.
pub trait KeySource: Send + Sync {
    fn fetch(&self) -> BoxFuture<'_, Result<FetchedKeys, String>>;
}

/// Fetches the JWKS over HTTP.
pub struct HttpKeySource {
    client: reqwest::Client,
    url: String,
}

impl HttpKeySource {
    pub fn new(url: impl Into<String>) -> Result<Self, String> {
        let client = reqwest::Client::builder()
            .timeout(FETCH_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|e| format!("could not build the HTTP client: {e}"))?;
        Ok(Self {
            client,
            url: url.into(),
        })
    }
}

impl KeySource for HttpKeySource {
    fn fetch(&self) -> BoxFuture<'_, Result<FetchedKeys, String>> {
        Box::pin(async move {
            let res = self
                .client
                .get(&self.url)
                .send()
                .await
                .map_err(|e| format!("fetching the App Check keys failed: {e}"))?;
            if !res.status().is_success() {
                return Err(format!(
                    "fetching the App Check keys failed: HTTP {}",
                    res.status()
                ));
            }
            let max_age = res
                .headers()
                .get(reqwest::header::CACHE_CONTROL)
                .and_then(|v| v.to_str().ok())
                .and_then(parse_max_age);
            // The body is JSON whatever its Content-Type says.
            let body = res
                .bytes()
                .await
                .map_err(|e| format!("reading the App Check keys failed: {e}"))?;
            if body.len() > MAX_JWKS_BYTES {
                return Err("the App Check key set is unreasonably large".into());
            }
            Ok(FetchedKeys {
                keys: parse_jwks(&body)?,
                max_age,
            })
        })
    }
}

/// A fixed key set, for tests.
pub struct StaticKeySource {
    json: String,
    max_age: Option<Duration>,
}

impl StaticKeySource {
    pub fn new(jwks_json: impl Into<String>) -> Self {
        Self {
            json: jwks_json.into(),
            max_age: None,
        }
    }

    pub fn with_max_age(mut self, max_age: Duration) -> Self {
        self.max_age = Some(max_age);
        self
    }
}

impl KeySource for StaticKeySource {
    fn fetch(&self) -> BoxFuture<'_, Result<FetchedKeys, String>> {
        Box::pin(async move {
            Ok(FetchedKeys {
                keys: parse_jwks(self.json.as_bytes())?,
                max_age: self.max_age,
            })
        })
    }
}

/// A key source that always fails, for tests of the 503 path.
pub struct FailingKeySource;

impl KeySource for FailingKeySource {
    fn fetch(&self) -> BoxFuture<'_, Result<FetchedKeys, String>> {
        Box::pin(async { Err("key source is down".to_string()) })
    }
}

/// Reads the RSA signing keys of a JWKS document, by `kid`. Keys of other
/// types, or without a `kid`, are skipped.
pub fn parse_jwks(body: &[u8]) -> Result<HashMap<String, DecodingKey>, String> {
    #[derive(Deserialize)]
    struct Doc {
        keys: Vec<serde_json::Value>,
    }
    let doc: Doc = serde_json::from_slice(body)
        .map_err(|e| format!("the App Check key set is not valid JSON: {e}"))?;
    let mut keys = HashMap::new();
    for value in doc.keys {
        let Ok(jwk) = serde_json::from_value::<Jwk>(value) else {
            continue;
        };
        let Some(kid) = jwk.common.key_id.clone() else {
            continue;
        };
        if !matches!(
            jwk.algorithm,
            jsonwebtoken::jwk::AlgorithmParameters::RSA(_)
        ) {
            continue;
        }
        if let Ok(key) = DecodingKey::from_jwk(&jwk) {
            keys.insert(kid, key);
        }
    }
    if keys.is_empty() {
        return Err("the App Check key set has no usable RSA keys".into());
    }
    Ok(keys)
}

/// `max-age=N` from a `Cache-Control` value.
pub fn parse_max_age(cache_control: &str) -> Option<Duration> {
    cache_control.split(',').find_map(|part| {
        let (name, value) = part.trim().split_once('=')?;
        if name.trim().eq_ignore_ascii_case("max-age") {
            value
                .trim()
                .trim_matches('"')
                .parse::<u64>()
                .ok()
                .map(Duration::from_secs)
        } else {
            None
        }
    })
}

/// How long to wait before refreshing keys fetched with this `max-age`: the
/// clamped TTL minus the safety margin, but never less than a minute.
pub fn refresh_delay(max_age: Option<Duration>) -> Duration {
    let ttl = max_age.unwrap_or(DEFAULT_TTL).clamp(MIN_TTL, MAX_TTL);
    ttl.saturating_sub(REFRESH_BEFORE_EXPIRY)
        .max(MIN_REFRESH_GAP)
}

struct Loaded {
    keys: Arc<HashMap<String, DecodingKey>>,
    fetched_at: Instant,
}

/// The result of looking a `kid` up.
pub enum Lookup {
    Found(DecodingKey),
    /// The key set is loaded but has no such `kid`.
    NotFound,
    /// No usable key set (not loaded yet, or too old).
    Unavailable,
}

/// Cached public keys with background and on-demand refresh.
pub struct KeyCache {
    source: Arc<dyn KeySource>,
    loaded: RwLock<Option<Loaded>>,
    /// Serialises refreshes triggered by an unknown `kid`; holds when the
    /// last one started.
    miss_refresh: Mutex<Option<Instant>>,
}

impl KeyCache {
    pub fn new(source: Arc<dyn KeySource>) -> Arc<Self> {
        Arc::new(Self {
            source,
            loaded: RwLock::new(None),
            miss_refresh: Mutex::new(None),
        })
    }

    /// The loaded keys, unless they are older than 24 hours (then they are dropped).
    fn snapshot(&self) -> Option<Arc<HashMap<String, DecodingKey>>> {
        {
            let guard = self.loaded.read().unwrap();
            match &*guard {
                None => return None,
                Some(l) if l.fetched_at.elapsed() < MAX_KEY_AGE => return Some(l.keys.clone()),
                Some(_) => {}
            }
        }
        let mut guard = self.loaded.write().unwrap();
        if guard
            .as_ref()
            .is_some_and(|l| l.fetched_at.elapsed() >= MAX_KEY_AGE)
        {
            tracing::error!(
                event = "app_check_keys_expired",
                "no successful App Check key refresh for 24 hours: dropping the keys"
            );
            *guard = None;
        }
        guard.as_ref().map(|l| l.keys.clone())
    }

    /// Whether `/run` can verify tokens right now.
    pub fn ready(&self) -> bool {
        self.snapshot().is_some()
    }

    /// Seconds since the keys were last fetched, for the summary.
    pub fn age_secs(&self) -> Option<u64> {
        self.loaded
            .read()
            .unwrap()
            .as_ref()
            .map(|l| l.fetched_at.elapsed().as_secs())
    }

    /// Fetches and stores the keys. Returns when the next refresh is due.
    /// On failure the old keys stay.
    pub async fn refresh_now(&self) -> Result<Duration, String> {
        let fetched = self.source.fetch().await?;
        let delay = refresh_delay(fetched.max_age);
        *self.loaded.write().unwrap() = Some(Loaded {
            keys: Arc::new(fetched.keys),
            fetched_at: Instant::now(),
        });
        Ok(delay)
    }

    /// Fetches the keys at startup and keeps them fresh. Never returns.
    /// Failures retry with a backoff of 1 s, doubling to 60 s.
    pub async fn run_refresh_loop(self: Arc<Self>) {
        let mut backoff = Duration::from_secs(1);
        loop {
            match self.refresh_now().await {
                Ok(delay) => {
                    backoff = Duration::from_secs(1);
                    tracing::debug!(
                        event = "app_check_keys_refreshed",
                        next_in_secs = delay.as_secs()
                    );
                    tokio::time::sleep(delay).await;
                }
                Err(e) => {
                    tracing::warn!(
                        event = "app_check_keys_failed",
                        retry_in_secs = backoff.as_secs(),
                        "{e}"
                    );
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(Duration::from_secs(60));
                }
            }
        }
    }

    /// Finds the key for a `kid`. An unknown `kid` triggers at most one
    /// refresh per minute; concurrent lookups wait for it (up to 5 s).
    pub async fn lookup(&self, kid: &str) -> Lookup {
        let Some(keys) = self.snapshot() else {
            return Lookup::Unavailable;
        };
        if let Some(key) = keys.get(kid) {
            return Lookup::Found(key.clone());
        }
        let Ok(mut last) = tokio::time::timeout(MISS_WAIT, self.miss_refresh.lock()).await else {
            return Lookup::NotFound;
        };
        // Another request may have refreshed while this one waited.
        if let Some(key) = self.snapshot().and_then(|k| k.get(kid).cloned()) {
            return Lookup::Found(key);
        }
        if last.is_some_and(|t| t.elapsed() < MISS_REFRESH_GAP) {
            return Lookup::NotFound;
        }
        *last = Some(Instant::now());
        if let Err(e) = self.refresh_now().await {
            tracing::warn!(event = "app_check_keys_failed", "{e}");
        }
        match self.snapshot() {
            Some(keys) => keys
                .get(kid)
                .cloned()
                .map_or(Lookup::NotFound, Lookup::Found),
            None => Lookup::Unavailable,
        }
    }
}

/// Why a token was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthError {
    /// The token is not acceptable (401 `app_check_invalid`). The reason is
    /// for the log only.
    Invalid(&'static str),
    /// A valid token for an app that is not allowlisted (403).
    NotAllowed,
    /// No usable keys (503 `auth_unavailable`).
    Unavailable,
}

impl AuthError {
    /// The reason that goes to the log (never to the client).
    pub fn reason(&self) -> &'static str {
        match self {
            AuthError::Invalid(r) => r,
            AuthError::NotAllowed => "app_not_allowed",
            AuthError::Unavailable => "keys_unavailable",
        }
    }
}

/// A verified token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Verified {
    /// The Firebase app ID (`sub`).
    pub app_id: String,
    /// `android`, `ios` or `web` (from the app ID), else `none`.
    pub platform: &'static str,
}

#[derive(Deserialize)]
struct Claims {
    sub: String,
}

/// Verifies App Check tokens for one Firebase project.
pub struct AppCheck {
    cache: Arc<KeyCache>,
    issuer: String,
    audiences: Vec<String>,
    app_ids: HashSet<String>,
}

impl AppCheck {
    pub fn new(cfg: &AppCheckConfig, cache: Arc<KeyCache>) -> Self {
        let mut audiences = vec![format!("projects/{}", cfg.project_number)];
        if let Some(id) = &cfg.project_id {
            audiences.push(format!("projects/{id}"));
        }
        Self {
            cache,
            issuer: format!(
                "https://firebaseappcheck.googleapis.com/{}",
                cfg.project_number
            ),
            audiences,
            app_ids: cfg.app_ids.iter().cloned().collect(),
        }
    }

    pub fn cache(&self) -> &Arc<KeyCache> {
        &self.cache
    }

    pub async fn verify(&self, token: &str) -> Result<Verified, AuthError> {
        if token.len() > MAX_TOKEN_BYTES {
            return Err(AuthError::Invalid("token_too_long"));
        }
        let header = decode_header(token).map_err(|_| AuthError::Invalid("malformed"))?;
        // Never trust the token's own `alg`: only RS256 is accepted.
        if header.alg != Algorithm::RS256 {
            return Err(AuthError::Invalid("bad_alg"));
        }
        if header.typ.as_deref() != Some("JWT") {
            return Err(AuthError::Invalid("bad_typ"));
        }
        let kid = header.kid.ok_or(AuthError::Invalid("no_kid"))?;
        let key = match self.cache.lookup(&kid).await {
            Lookup::Found(key) => key,
            Lookup::NotFound => return Err(AuthError::Invalid("unknown_kid")),
            Lookup::Unavailable => return Err(AuthError::Unavailable),
        };

        let mut validation = Validation::new(Algorithm::RS256);
        validation.leeway = 60;
        validation.set_issuer(&[&self.issuer]);
        validation.set_audience(&self.audiences);
        validation.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
        let claims = decode::<Claims>(token, &key, &validation)
            .map_err(|e| AuthError::Invalid(reason_for(e.kind())))?
            .claims;

        if !self.app_ids.contains(&claims.sub) {
            return Err(AuthError::NotAllowed);
        }
        let platform = claims
            .sub
            .split(':')
            .nth(2)
            .and_then(|p| ["android", "ios", "web"].into_iter().find(|k| *k == p))
            .unwrap_or("none");
        Ok(Verified {
            app_id: claims.sub,
            platform,
        })
    }
}

fn reason_for(kind: &ErrorKind) -> &'static str {
    match kind {
        ErrorKind::ExpiredSignature => "expired",
        ErrorKind::InvalidIssuer => "bad_issuer",
        ErrorKind::InvalidAudience => "bad_audience",
        ErrorKind::InvalidSignature => "bad_signature",
        ErrorKind::InvalidAlgorithm => "bad_alg",
        ErrorKind::MissingRequiredClaim(_) => "missing_claim",
        ErrorKind::InvalidSubject => "bad_subject",
        ErrorKind::ImmatureSignature => "not_yet_valid",
        _ => "invalid",
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use jsonwebtoken::{EncodingKey, Header, encode, get_current_timestamp};
    use serde_json::json;

    use super::*;

    const JWKS: &str = include_str!("../tests/fixtures/jwks.json");
    const KEY1: &str = include_str!("../tests/fixtures/test-key-1.pem");
    const KEY2: &str = include_str!("../tests/fixtures/test-key-2.pem");
    const NUMBER: &str = "123456789012";
    const PROJECT_ID: &str = "my-project-1";
    const APP: &str = "1:123456789012:android:0123abcd";

    fn config() -> AppCheckConfig {
        AppCheckConfig {
            project_number: NUMBER.into(),
            project_id: Some(PROJECT_ID.into()),
            app_ids: vec![APP.into(), "1:123456789012:ios:4567".into()],
            jwks_url: "unused".into(),
        }
    }

    async fn verifier() -> AppCheck {
        let cache = KeyCache::new(Arc::new(StaticKeySource::new(JWKS)));
        cache.refresh_now().await.unwrap();
        AppCheck::new(&config(), cache)
    }

    fn claims(exp_offset: i64) -> serde_json::Value {
        json!({
            "iss": format!("https://firebaseappcheck.googleapis.com/{NUMBER}"),
            "aud": [format!("projects/{NUMBER}"), format!("projects/{PROJECT_ID}")],
            "sub": APP,
            "exp": get_current_timestamp() as i64 + exp_offset,
            "iat": get_current_timestamp(),
        })
    }

    fn sign(pem: &str, kid: Option<&str>, typ: Option<&str>, claims: &serde_json::Value) -> String {
        let mut header = Header::new(Algorithm::RS256);
        header.kid = kid.map(str::to_string);
        header.typ = typ.map(str::to_string);
        encode(
            &header,
            claims,
            &EncodingKey::from_rsa_pem(pem.as_bytes()).unwrap(),
        )
        .unwrap()
    }

    fn valid(claims: &serde_json::Value) -> String {
        sign(KEY1, Some("test-1"), Some("JWT"), claims)
    }

    #[tokio::test]
    async fn valid_token_is_accepted() {
        let v = verifier()
            .await
            .verify(&valid(&claims(3600)))
            .await
            .unwrap();
        assert_eq!(v.app_id, APP);
        assert_eq!(v.platform, "android");
        // The second key works too.
        let t = sign(KEY2, Some("test-2"), Some("JWT"), &claims(3600));
        assert!(verifier().await.verify(&t).await.is_ok());
    }

    #[tokio::test]
    async fn expiry_has_sixty_seconds_of_leeway() {
        let v = verifier().await;
        assert_eq!(
            v.verify(&valid(&claims(-61))).await.unwrap_err(),
            AuthError::Invalid("expired")
        );
        assert!(v.verify(&valid(&claims(-30))).await.is_ok());
    }

    #[tokio::test]
    async fn issuer_and_audience_must_match() {
        let v = verifier().await;
        let mut c = claims(3600);
        c["iss"] = json!("https://firebaseappcheck.googleapis.com/999");
        assert_eq!(
            v.verify(&valid(&c)).await.unwrap_err(),
            AuthError::Invalid("bad_issuer")
        );

        let mut c = claims(3600);
        c["aud"] = json!(["projects/999", "projects/other"]);
        assert_eq!(
            v.verify(&valid(&c)).await.unwrap_err(),
            AuthError::Invalid("bad_audience")
        );

        // Either the project number or the project ID is accepted.
        let mut c = claims(3600);
        c["aud"] = json!([format!("projects/{PROJECT_ID}")]);
        assert!(v.verify(&valid(&c)).await.is_ok());
        let mut c = claims(3600);
        c["aud"] = json!([format!("projects/{NUMBER}")]);
        assert!(v.verify(&valid(&c)).await.is_ok());

        let mut c = claims(3600);
        c.as_object_mut().unwrap().remove("iss");
        assert!(v.verify(&valid(&c)).await.is_err());
        let mut c = claims(3600);
        c.as_object_mut().unwrap().remove("exp");
        assert!(v.verify(&valid(&c)).await.is_err());
    }

    #[tokio::test]
    async fn app_must_be_allowlisted() {
        let v = verifier().await;
        let mut c = claims(3600);
        c["sub"] = json!("1:123456789012:android:ffff");
        assert_eq!(
            v.verify(&valid(&c)).await.unwrap_err(),
            AuthError::NotAllowed
        );
        let mut c = claims(3600);
        c.as_object_mut().unwrap().remove("sub");
        assert!(matches!(
            v.verify(&valid(&c)).await,
            Err(AuthError::Invalid(_))
        ));
    }

    #[tokio::test]
    async fn key_problems_are_rejected() {
        let v = verifier().await;
        let c = claims(3600);
        // Unknown kid.
        let t = sign(KEY1, Some("nope"), Some("JWT"), &c);
        assert_eq!(
            v.verify(&t).await.unwrap_err(),
            AuthError::Invalid("unknown_kid")
        );
        // No kid at all.
        let t = sign(KEY1, None, Some("JWT"), &c);
        assert_eq!(
            v.verify(&t).await.unwrap_err(),
            AuthError::Invalid("no_kid")
        );
        // Signed with key 2 but claiming key 1.
        let t = sign(KEY2, Some("test-1"), Some("JWT"), &c);
        assert_eq!(
            v.verify(&t).await.unwrap_err(),
            AuthError::Invalid("bad_signature")
        );
        // `typ` missing or wrong.
        let t = sign(KEY1, Some("test-1"), None, &c);
        assert_eq!(
            v.verify(&t).await.unwrap_err(),
            AuthError::Invalid("bad_typ")
        );
        let t = sign(KEY1, Some("test-1"), Some("at+jwt"), &c);
        assert_eq!(
            v.verify(&t).await.unwrap_err(),
            AuthError::Invalid("bad_typ")
        );
    }

    fn b64(bytes: &[u8]) -> String {
        use base64::Engine;
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
    }

    #[tokio::test]
    async fn algorithm_confusion_is_rejected() {
        let v = verifier().await;
        let c = claims(3600);
        // HS256 signed with the public key bytes as the secret.
        let mut header = Header::new(Algorithm::HS256);
        header.kid = Some("test-1".into());
        let public = JWKS.as_bytes();
        let t = encode(&header, &c, &EncodingKey::from_secret(public)).unwrap();
        assert_eq!(
            v.verify(&t).await.unwrap_err(),
            AuthError::Invalid("bad_alg")
        );

        // alg: none.
        let h = b64(br#"{"alg":"none","typ":"JWT","kid":"test-1"}"#);
        let t = format!("{h}.{}.", b64(c.to_string().as_bytes()));
        assert!(matches!(v.verify(&t).await, Err(AuthError::Invalid(_))));
        // RS256 header, empty signature.
        let h = b64(br#"{"alg":"RS256","typ":"JWT","kid":"test-1"}"#);
        let t = format!("{h}.{}.", b64(c.to_string().as_bytes()));
        assert!(matches!(v.verify(&t).await, Err(AuthError::Invalid(_))));
    }

    #[tokio::test]
    async fn junk_and_oversized_tokens_are_rejected() {
        let v = verifier().await;
        for junk in ["", "abc", "a.b.c", "....", "é.é.é"] {
            assert!(
                matches!(v.verify(junk).await, Err(AuthError::Invalid(_))),
                "{junk:?}"
            );
        }
        let mut c = claims(3600);
        c["pad"] = json!("x".repeat(MAX_TOKEN_BYTES));
        let t = valid(&c);
        assert!(t.len() > MAX_TOKEN_BYTES);
        assert_eq!(
            v.verify(&t).await.unwrap_err(),
            AuthError::Invalid("token_too_long")
        );
    }

    #[tokio::test]
    async fn no_keys_means_unavailable() {
        let cache = KeyCache::new(Arc::new(FailingKeySource));
        let v = AppCheck::new(&config(), cache);
        assert_eq!(
            v.verify(&valid(&claims(3600))).await.unwrap_err(),
            AuthError::Unavailable
        );
    }

    #[test]
    fn jwks_parsing_is_lenient_about_foreign_keys() {
        let fixture: serde_json::Value = serde_json::from_str(JWKS).unwrap();
        let mut good = fixture["keys"][0].clone();
        good["kid"] = json!("good");
        // Real Google keys carry `alg` and `use`; a key without them works too.
        good.as_object_mut().unwrap().remove("alg");
        good.as_object_mut().unwrap().remove("use");
        let body = json!({"keys": [
            {"kty":"oct","kid":"hmac","k":"c2VjcmV0"},
            good,
            {"kty":"RSA","n":fixture["keys"][0]["n"],"e":"AQAB"},
            {"kty":"EC","kid":"ec","crv":"P-256","x":"AAAA","y":"AAAA"},
            "not even an object"
        ]})
        .to_string();
        let keys = parse_jwks(body.as_bytes()).unwrap();
        assert_eq!(keys.keys().collect::<Vec<_>>(), vec!["good"]);
        assert!(parse_jwks(b"{\"keys\":[]}").is_err());
        assert!(parse_jwks(b"not json").is_err());
    }

    #[test]
    fn max_age_parsing_and_refresh_delay() {
        assert_eq!(
            parse_max_age("public, max-age=21600"),
            Some(Duration::from_secs(21600))
        );
        assert_eq!(parse_max_age("no-store"), None);
        assert_eq!(parse_max_age("Max-Age=60"), Some(Duration::from_secs(60)));
        // Clamped to 5 min - 6 h, refreshed 5 min early, at least a minute apart.
        assert_eq!(
            refresh_delay(Some(Duration::from_secs(21600))),
            Duration::from_secs(21600 - 300)
        );
        assert_eq!(
            refresh_delay(Some(Duration::from_secs(10 * 3600))),
            Duration::from_secs(21600 - 300)
        );
        assert_eq!(
            refresh_delay(Some(Duration::from_secs(1))),
            Duration::from_secs(60)
        );
        assert_eq!(
            refresh_delay(Some(Duration::from_secs(900))),
            Duration::from_secs(600)
        );
        assert_eq!(refresh_delay(None), Duration::from_secs(3300));
    }

    // --- key cache, with a counting fake source and paused time ---

    struct FakeSource {
        hits: AtomicUsize,
        fail: std::sync::atomic::AtomicBool,
        max_age: Option<Duration>,
        latency: Duration,
        /// kids served, switchable to simulate a key rotation.
        kids: Mutex<Vec<&'static str>>,
    }

    impl FakeSource {
        fn new(max_age: Option<Duration>) -> Arc<Self> {
            Arc::new(Self {
                hits: AtomicUsize::new(0),
                fail: Default::default(),
                max_age,
                latency: Duration::from_millis(20),
                kids: Mutex::new(vec!["test-1"]),
            })
        }
        fn hits(&self) -> usize {
            self.hits.load(Ordering::SeqCst)
        }
    }

    impl KeySource for FakeSource {
        fn fetch(&self) -> BoxFuture<'_, Result<FetchedKeys, String>> {
            Box::pin(async move {
                self.hits.fetch_add(1, Ordering::SeqCst);
                tokio::time::sleep(self.latency).await;
                if self.fail.load(Ordering::SeqCst) {
                    return Err("down".into());
                }
                let all = parse_jwks(JWKS.as_bytes()).unwrap();
                let kids = self.kids.lock().await.clone();
                Ok(FetchedKeys {
                    keys: all
                        .into_iter()
                        .filter(|(k, _)| kids.contains(&k.as_str()))
                        .collect(),
                    max_age: self.max_age,
                })
            })
        }
    }

    fn found(l: Lookup) -> bool {
        matches!(l, Lookup::Found(_))
    }

    #[tokio::test(start_paused = true)]
    async fn refreshes_before_the_keys_expire() {
        let src = FakeSource::new(Some(Duration::from_secs(6 * 3600)));
        let cache = KeyCache::new(src.clone());
        tokio::spawn(cache.clone().run_refresh_loop());
        tokio::time::sleep(Duration::from_secs(1)).await;
        assert_eq!(src.hits(), 1);
        assert!(cache.ready());
        // 5 h 54 min after the first fetch: not yet.
        tokio::time::sleep(Duration::from_secs(5 * 3600 + 54 * 60)).await;
        assert_eq!(src.hits(), 1);
        // Past 5 h 55 min: refreshed.
        tokio::time::sleep(Duration::from_secs(3 * 60)).await;
        assert_eq!(src.hits(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn short_max_age_is_clamped() {
        let src = FakeSource::new(Some(Duration::from_secs(1)));
        let cache = KeyCache::new(src.clone());
        tokio::spawn(cache.clone().run_refresh_loop());
        tokio::time::sleep(Duration::from_secs(30)).await;
        assert_eq!(src.hits(), 1, "max-age=1 must not cause a refresh storm");
        tokio::time::sleep(Duration::from_secs(60)).await;
        assert_eq!(src.hits(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn many_unknown_kid_lookups_cause_one_fetch() {
        let src = FakeSource::new(None);
        let cache = KeyCache::new(src.clone());
        cache.refresh_now().await.unwrap();
        assert_eq!(src.hits(), 1);
        let mut tasks = Vec::new();
        for _ in 0..50 {
            let c = cache.clone();
            tasks.push(tokio::spawn(async move { c.lookup("test-2").await }));
        }
        for t in tasks {
            assert!(matches!(t.await.unwrap(), Lookup::NotFound));
        }
        assert_eq!(src.hits(), 2, "50 concurrent misses share one refresh");
    }

    #[tokio::test(start_paused = true)]
    async fn second_unknown_kid_within_a_minute_does_not_fetch() {
        let src = FakeSource::new(None);
        let cache = KeyCache::new(src.clone());
        cache.refresh_now().await.unwrap();
        assert!(matches!(cache.lookup("a").await, Lookup::NotFound));
        assert_eq!(src.hits(), 2);
        tokio::time::sleep(Duration::from_secs(30)).await;
        assert!(matches!(cache.lookup("b").await, Lookup::NotFound));
        assert_eq!(src.hits(), 2, "within 60 s of the last miss refresh");
        tokio::time::sleep(Duration::from_secs(31)).await;
        assert!(matches!(cache.lookup("c").await, Lookup::NotFound));
        assert_eq!(src.hits(), 3);
    }

    #[tokio::test(start_paused = true)]
    async fn rotated_key_is_found_after_one_refresh() {
        let src = FakeSource::new(None);
        let cache = KeyCache::new(src.clone());
        cache.refresh_now().await.unwrap();
        assert!(found(cache.lookup("test-1").await));
        src.kids.lock().await.push("test-2");
        assert!(found(cache.lookup("test-2").await));
        assert_eq!(src.hits(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn failed_fetch_keeps_the_old_keys() {
        let src = FakeSource::new(Some(Duration::from_secs(600)));
        let cache = KeyCache::new(src.clone());
        tokio::spawn(cache.clone().run_refresh_loop());
        tokio::time::sleep(Duration::from_secs(1)).await;
        src.fail.store(true, Ordering::SeqCst);
        tokio::time::sleep(Duration::from_secs(3600)).await;
        assert!(src.hits() > 2, "kept retrying: {}", src.hits());
        assert!(cache.ready());
        assert!(found(cache.lookup("test-1").await));
        // A miss while the source is down doesn't drop the keys either.
        assert!(matches!(cache.lookup("zzz").await, Lookup::NotFound));
        assert!(cache.ready());
    }

    #[tokio::test(start_paused = true)]
    async fn keys_older_than_a_day_are_dropped() {
        let src = FakeSource::new(Some(Duration::from_secs(600)));
        let cache = KeyCache::new(src.clone());
        tokio::spawn(cache.clone().run_refresh_loop());
        tokio::time::sleep(Duration::from_secs(1)).await;
        src.fail.store(true, Ordering::SeqCst);
        tokio::time::sleep(Duration::from_secs(23 * 3600)).await;
        assert!(cache.ready(), "still within 24 h");
        tokio::time::sleep(Duration::from_secs(2 * 3600)).await;
        assert!(!cache.ready());
        assert!(matches!(cache.lookup("test-1").await, Lookup::Unavailable));
        // Recovery: when the source comes back, keys load again.
        src.fail.store(false, Ordering::SeqCst);
        tokio::time::sleep(Duration::from_secs(120)).await;
        assert!(cache.ready());
    }

    #[tokio::test(start_paused = true)]
    async fn startup_retries_with_backoff_until_keys_load() {
        let src = FakeSource::new(None);
        src.fail.store(true, Ordering::SeqCst);
        let cache = KeyCache::new(src.clone());
        tokio::spawn(cache.clone().run_refresh_loop());
        tokio::time::sleep(Duration::from_secs(10)).await;
        assert!(!cache.ready());
        assert!(
            (3..=5).contains(&src.hits()),
            "1+2+4 s backoff: {}",
            src.hits()
        );
        src.fail.store(false, Ordering::SeqCst);
        tokio::time::sleep(Duration::from_secs(70)).await;
        assert!(cache.ready());
    }
}
