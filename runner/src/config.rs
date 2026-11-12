//! Configuration from environment variables, with fail-closed production rules.
//!
//! `RUNNER_ENV` defaults to `production`. In production the server refuses
//! to start unless App Check is configured, the runtime is gVisor, CORS
//! origins are explicit, rate limits are on and the listen address is
//! loopback (a reverse proxy faces the internet). Every problem is reported
//! at once.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::str::FromStr;
use std::time::Duration;

use crate::client_ip::TrustedProxies;
use crate::sandbox::Limits;

pub const DEFAULT_JWKS_URL: &str = "https://firebaseappcheck.googleapis.com/v1/jwks";
pub const DEFAULT_IMAGE: &str = "rust-runner-sandbox";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunnerEnv {
    Production,
    Development,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppCheckMode {
    Required,
    Off,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogFormat {
    Json,
    Text,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SandboxChoice {
    Docker {
        image: String,
        /// `runsc` for gVisor; `None` is Docker's default (development only).
        runtime: Option<String>,
    },
    /// Unsandboxed, development only.
    Local,
}

/// One scope's two buckets. `per_min` with `burst` is the short bucket;
/// `per_hour` is the hourly one (its burst is the whole hour's allowance).
/// 0 switches a bucket off, in development only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BucketConfig {
    pub per_min: u32,
    pub burst: u32,
    pub per_hour: u32,
}

impl BucketConfig {
    pub const OFF: Self = Self {
        per_min: 0,
        burst: 0,
        per_hour: 0,
    };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RateConfig {
    pub token: BucketConfig,
    pub ip: BucketConfig,
    pub max_keys: usize,
}

impl RateConfig {
    pub const OFF: Self = Self {
        token: BucketConfig::OFF,
        ip: BucketConfig::OFF,
        max_keys: 50_000,
    };
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppCheckConfig {
    pub project_number: String,
    pub project_id: Option<String>,
    pub app_ids: Vec<String>,
    pub jwks_url: String,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub env: RunnerEnv,
    pub addr: SocketAddr,
    pub limits: Limits,
    pub max_jobs: usize,
    pub max_queued: usize,
    /// Most requests one client IP or one App Check token may have running
    /// or queued at once (`RUNNER_MAX_INFLIGHT_PER_CLIENT`).
    pub max_inflight_per_client: usize,
    /// Per-IP cap for requests with a verified App Check token
    /// (`RUNNER_MAX_INFLIGHT_PER_VERIFIED_IP`).
    pub max_inflight_per_verified_ip: usize,
    pub queue_timeout: Duration,
    pub sandbox: SandboxChoice,
    /// `Some` when App Check is required.
    pub app_check: Option<AppCheckConfig>,
    pub trusted_proxies: TrustedProxies,
    pub rate: RateConfig,
    pub allowed_origins: Vec<String>,
    pub log_format: LogFormat,
}

impl Config {
    /// Reads the process environment.
    pub fn from_env() -> Result<Self, Vec<String>> {
        let map: HashMap<String, String> = std::env::vars().collect();
        Self::from_env_map(&map)
    }

    /// Builds a config from variables. Returns every problem found.
    pub fn from_env_map(vars: &HashMap<String, String>) -> Result<Self, Vec<String>> {
        let mut p = Parser {
            vars,
            errors: Vec::new(),
        };
        let cfg = p.parse();
        if p.errors.is_empty() {
            Ok(cfg)
        } else {
            Err(p.errors)
        }
    }

    /// Whether this is a production config.
    pub fn is_production(&self) -> bool {
        self.env == RunnerEnv::Production
    }
}

struct Parser<'a> {
    vars: &'a HashMap<String, String>,
    errors: Vec<String>,
}

impl<'a> Parser<'a> {
    /// The variable's value, trimmed. Empty counts as unset (a systemd
    /// `EnvironmentFile` line `FOO=` sets an empty value).
    fn get(&self, key: &str) -> Option<&'a str> {
        self.vars
            .get(key)
            .map(|v| v.trim())
            .filter(|v| !v.is_empty())
    }

    fn err(&mut self, message: impl Into<String>) {
        self.errors.push(message.into());
    }

    fn num<T: FromStr>(&mut self, key: &str, default: T) -> T {
        match self.get(key) {
            None => default,
            Some(v) => v.parse().unwrap_or_else(|_| {
                self.err(format!("{key} has an invalid value: {v}"));
                default
            }),
        }
    }

    fn parse(&mut self) -> Config {
        let env = match self.get("RUNNER_ENV") {
            None | Some("production") => RunnerEnv::Production,
            Some("development") => RunnerEnv::Development,
            Some(other) => {
                self.err(format!(
                    "RUNNER_ENV must be `production` or `development`, not {other:?}"
                ));
                RunnerEnv::Production
            }
        };
        let prod = env == RunnerEnv::Production;

        let addr = self.addr(prod);
        let limits = self.limits();
        let max_jobs: usize = self.num("RUNNER_MAX_JOBS", 4);
        if max_jobs == 0 {
            self.err("RUNNER_MAX_JOBS must be at least 1");
        }
        let max_queued: usize = self.num("RUNNER_MAX_QUEUED", 16);
        if max_queued > 1000 {
            self.err("RUNNER_MAX_QUEUED must be at most 1000");
        }
        let max_inflight_per_client: usize = self.num("RUNNER_MAX_INFLIGHT_PER_CLIENT", 1);
        if !(1..=100).contains(&max_inflight_per_client) {
            self.err("RUNNER_MAX_INFLIGHT_PER_CLIENT must be between 1 and 100");
        }
        let max_inflight_per_verified_ip: usize =
            self.num("RUNNER_MAX_INFLIGHT_PER_VERIFIED_IP", 4);
        if !(1..=1000).contains(&max_inflight_per_verified_ip)
            || max_inflight_per_verified_ip < max_inflight_per_client
        {
            self.err(
                "RUNNER_MAX_INFLIGHT_PER_VERIFIED_IP must be between 1 and 1000 and at least RUNNER_MAX_INFLIGHT_PER_CLIENT",
            );
        }
        let queue_secs: u64 = self.num("RUNNER_QUEUE_TIMEOUT_SECS", 10);
        if queue_secs > 600 {
            self.err("RUNNER_QUEUE_TIMEOUT_SECS must be at most 600");
        }

        let sandbox = self.sandbox(prod);
        let app_check = self.app_check(prod);
        let trusted_proxies = self.trusted_proxies(prod);
        let rate = self.rate(prod);
        let allowed_origins = self.origins(prod);

        let log_format = match self.get("RUNNER_LOG_FORMAT") {
            None => {
                if prod {
                    LogFormat::Json
                } else {
                    LogFormat::Text
                }
            }
            Some("json") => LogFormat::Json,
            Some("text") => LogFormat::Text,
            Some(other) => {
                self.err(format!(
                    "RUNNER_LOG_FORMAT must be `json` or `text`, not {other:?}"
                ));
                LogFormat::Json
            }
        };
        if let Some(filter) = self.get("RUST_LOG")
            && let Err(e) = tracing_subscriber::EnvFilter::try_new(filter)
        {
            self.err(format!("RUST_LOG is not a valid filter: {e}"));
        }

        Config {
            env,
            addr,
            limits,
            max_jobs,
            max_queued,
            max_inflight_per_client,
            max_inflight_per_verified_ip,
            queue_timeout: Duration::from_secs(queue_secs),
            sandbox,
            app_check,
            trusted_proxies,
            rate,
            allowed_origins,
            log_format,
        }
    }

    fn addr(&mut self, prod: bool) -> SocketAddr {
        let fallback: SocketAddr = ([0, 0, 0, 0], 8080).into();
        let Some(text) = self.get("RUNNER_ADDR") else {
            if prod {
                self.err(
                    "RUNNER_ADDR must be a loopback address in production (e.g. 127.0.0.1:8080); the default 0.0.0.0:8080 is not",
                );
            }
            return fallback;
        };
        match text.parse::<SocketAddr>() {
            Ok(addr) => {
                if prod && !addr.ip().is_loopback() {
                    self.err(format!(
                        "RUNNER_ADDR must be a loopback address in production, not {addr}; put Caddy in front"
                    ));
                }
                addr
            }
            Err(_) => {
                self.err(format!("RUNNER_ADDR is not a socket address: {text}"));
                fallback
            }
        }
    }

    fn limits(&mut self) -> Limits {
        let defaults = Limits::default();
        let limits = Limits {
            compile_timeout: Duration::from_secs(self.num("RUNNER_COMPILE_TIMEOUT_SECS", 10)),
            run_timeout: Duration::from_secs(self.num("RUNNER_RUN_TIMEOUT_SECS", 5)),
            job_timeout: Duration::from_secs(self.num("RUNNER_JOB_TIMEOUT_SECS", 20)),
            memory_mb: self.num("RUNNER_MEMORY_MB", defaults.memory_mb),
            ..defaults
        };
        if let Err(e) = limits.validate() {
            self.err(e);
        }
        limits
    }

    fn sandbox(&mut self, prod: bool) -> SandboxChoice {
        let kind = self.get("RUNNER_SANDBOX");
        let runtime = self.get("RUNNER_DOCKER_RUNTIME").map(str::to_string);
        let allow_runc = self.get("RUNNER_ALLOW_RUNC");

        match kind {
            None | Some("docker") => {}
            Some("local") => {
                if prod {
                    self.err(
                        "RUNNER_SANDBOX=local runs code unsandboxed and is refused in production",
                    );
                }
                return SandboxChoice::Local;
            }
            Some(other) => {
                self.err(format!(
                    "RUNNER_SANDBOX must be `docker` or `local`, not {other:?}"
                ));
            }
        }
        if prod {
            if runtime.as_deref() != Some("runsc") {
                self.err("RUNNER_DOCKER_RUNTIME must be `runsc` (gVisor) in production");
            }
            if allow_runc.is_some() {
                self.err("RUNNER_ALLOW_RUNC must not be set in production");
            }
        } else if runtime.is_none() && allow_runc != Some("1") {
            // Plain runc shares the host kernel; gVisor (runsc) adds a
            // user-space kernel between learner code and the host.
            self.err(
                "set RUNNER_DOCKER_RUNTIME=runsc (gVisor), or RUNNER_ALLOW_RUNC=1 to use Docker's default runtime (runc) in development",
            );
        }
        SandboxChoice::Docker {
            image: self
                .get("RUNNER_IMAGE")
                .unwrap_or(DEFAULT_IMAGE)
                .to_string(),
            runtime,
        }
    }

    fn app_check(&mut self, prod: bool) -> Option<AppCheckConfig> {
        let mode = match self.get("RUNNER_APP_CHECK") {
            None => {
                if prod {
                    AppCheckMode::Required
                } else {
                    AppCheckMode::Off
                }
            }
            Some("required") => AppCheckMode::Required,
            Some("off") => {
                if prod {
                    self.err("RUNNER_APP_CHECK must be `required` in production");
                }
                AppCheckMode::Off
            }
            Some(other) => {
                self.err(format!(
                    "RUNNER_APP_CHECK must be `required` or `off`, not {other:?}"
                ));
                AppCheckMode::Required
            }
        };

        // Validate whatever is given, even when App Check is off.
        let number = self
            .get("RUNNER_FIREBASE_PROJECT_NUMBER")
            .map(str::to_string);
        if let Some(n) = &number
            && !((1..=20).contains(&n.len()) && n.bytes().all(|b| b.is_ascii_digit()))
        {
            self.err("RUNNER_FIREBASE_PROJECT_NUMBER must be 1-20 digits");
        }
        let project_id = self.get("RUNNER_FIREBASE_PROJECT_ID").map(str::to_string);
        if let Some(id) = &project_id
            && !valid_project_id(id)
        {
            self.err(format!(
                "RUNNER_FIREBASE_PROJECT_ID is not a Firebase project ID (lowercase letters, digits, hyphens; 5-30 characters): {id}"
            ));
        }
        let mut app_ids = Vec::new();
        let mut app_ids_malformed = false;
        if let Some(list) = self.get("RUNNER_APP_CHECK_APP_IDS") {
            for id in list.split(',').map(str::trim).filter(|i| !i.is_empty()) {
                if valid_app_id(id) {
                    app_ids.push(id.to_string());
                } else {
                    app_ids_malformed = true;
                    self.err(format!(
                        "RUNNER_APP_CHECK_APP_IDS has a malformed app ID (expected 1:<number>:<android|ios|web>:<hex>): {id}"
                    ));
                }
            }
        }
        let jwks_url = match self.get("RUNNER_APP_CHECK_JWKS_URL") {
            None => DEFAULT_JWKS_URL.to_string(),
            Some(url) => {
                let https = url.starts_with("https://");
                let http_ok = !prod && url.starts_with("http://");
                if !(https || http_ok) || url.contains(char::is_whitespace) {
                    self.err(format!(
                        "RUNNER_APP_CHECK_JWKS_URL must be an https URL (http only in development): {url}"
                    ));
                } else if prod && url != DEFAULT_JWKS_URL {
                    self.err("RUNNER_APP_CHECK_JWKS_URL must be the default in production");
                }
                url.to_string()
            }
        };

        if mode == AppCheckMode::Off {
            return None;
        }
        if number.is_none() {
            self.err("RUNNER_FIREBASE_PROJECT_NUMBER is required when App Check is required");
        }
        // A list that parses to nothing (e.g. ",") is as bad as a missing one.
        if app_ids.is_empty() && !app_ids_malformed {
            self.err(
                "RUNNER_APP_CHECK_APP_IDS is required when App Check is required (at least one app ID)",
            );
        }
        Some(AppCheckConfig {
            project_number: number.unwrap_or_default(),
            project_id,
            app_ids,
            jwks_url,
        })
    }

    fn trusted_proxies(&mut self, prod: bool) -> TrustedProxies {
        let mut malformed = false;
        let proxies = match self.get("RUNNER_TRUSTED_PROXIES") {
            None => TrustedProxies::default(),
            Some(list) => match TrustedProxies::parse(list) {
                Ok(p) => p,
                Err(errors) => {
                    malformed = true;
                    for e in errors {
                        self.err(format!("RUNNER_TRUSTED_PROXIES: {e}"));
                    }
                    TrustedProxies::default()
                }
            },
        };
        // Missing, or a list that parses to nothing (e.g. ","): both leave the
        // runner unable to tell clients apart behind the proxy.
        if prod && proxies.is_empty() && !malformed {
            self.err(
                "RUNNER_TRUSTED_PROXIES is required in production and must list at least one range (e.g. 127.0.0.1/32,::1/128)",
            );
        }
        proxies
    }

    fn bucket(&mut self, prod: bool, prefix: &str, defaults: BucketConfig) -> BucketConfig {
        let per_min = self.num(&format!("RUNNER_LIMIT_{prefix}_PER_MIN"), defaults.per_min);
        let burst = self.num(&format!("RUNNER_LIMIT_{prefix}_BURST"), defaults.burst);
        let per_hour = self.num(
            &format!("RUNNER_LIMIT_{prefix}_PER_HOUR"),
            defaults.per_hour,
        );
        for (name, value) in [
            ("PER_MIN", per_min),
            ("BURST", burst),
            ("PER_HOUR", per_hour),
        ] {
            if prod && value == 0 {
                self.err(format!(
                    "RUNNER_LIMIT_{prefix}_{name} must be above 0 in production"
                ));
            }
        }
        if per_min > 0 && burst > per_min {
            self.err(format!(
                "RUNNER_LIMIT_{prefix}_BURST ({burst}) must not exceed RUNNER_LIMIT_{prefix}_PER_MIN ({per_min})"
            ));
        }
        if per_min > 0 && burst == 0 {
            self.err(format!(
                "RUNNER_LIMIT_{prefix}_BURST must be above 0 when RUNNER_LIMIT_{prefix}_PER_MIN is"
            ));
        }
        BucketConfig {
            per_min,
            burst,
            per_hour,
        }
    }

    fn rate(&mut self, prod: bool) -> RateConfig {
        let token = self.bucket(
            prod,
            "TOKEN",
            BucketConfig {
                per_min: 20,
                burst: 10,
                per_hour: 300,
            },
        );
        let ip = self.bucket(
            prod,
            "IP",
            BucketConfig {
                per_min: 120,
                burst: 60,
                per_hour: 3000,
            },
        );
        let max_keys: usize = self.num("RUNNER_LIMIT_MAX_KEYS", 50_000);
        if !(1000..=1_000_000).contains(&max_keys) {
            self.err("RUNNER_LIMIT_MAX_KEYS must be between 1000 and 1000000");
        }
        RateConfig {
            token,
            ip,
            max_keys,
        }
    }

    fn origins(&mut self, prod: bool) -> Vec<String> {
        let list: Vec<String> = self
            .get("RUNNER_ALLOWED_ORIGINS")
            .unwrap_or_default()
            .split(',')
            .map(|o| o.trim().to_string())
            .filter(|o| !o.is_empty())
            .collect();
        if prod && list.is_empty() {
            self.err("RUNNER_ALLOWED_ORIGINS must list the web origins that may call the runner in production");
        }
        for origin in &list {
            if origin == "*" {
                if prod {
                    self.err("RUNNER_ALLOWED_ORIGINS must not contain `*` in production");
                }
            } else if let Err(e) = check_origin(origin, !prod) {
                self.err(format!("RUNNER_ALLOWED_ORIGINS: {e}"));
            }
        }
        list
    }
}

/// `^[a-z][a-z0-9-]{4,29}$`
fn valid_project_id(id: &str) -> bool {
    let b = id.as_bytes();
    (5..=30).contains(&b.len())
        && b[0].is_ascii_lowercase()
        && b[1..]
            .iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
}

/// `^\d+:\d+:(android|ios|web):[0-9a-f]+$`
fn valid_app_id(id: &str) -> bool {
    let parts: Vec<&str> = id.split(':').collect();
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    parts.len() == 4
        && digits(parts[0])
        && digits(parts[1])
        && matches!(parts[2], "android" | "ios" | "web")
        && !parts[3].is_empty()
        && parts[3]
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// An origin is `https://host[:port]`, with no path. `http` is allowed in development.
fn check_origin(origin: &str, allow_http: bool) -> Result<(), String> {
    let rest = if let Some(rest) = origin.strip_prefix("https://") {
        rest
    } else if allow_http && let Some(rest) = origin.strip_prefix("http://") {
        rest
    } else {
        return Err(format!(
            "{origin:?} must look like https://host[:port]{}",
            if allow_http { " (or http://)" } else { "" }
        ));
    };
    let (host, port) = match rest.split_once(':') {
        Some((h, p)) => (h, Some(p)),
        None => (rest, None),
    };
    let host_ok = !host.is_empty()
        && host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-'));
    let port_ok = port.is_none_or(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()));
    if host_ok && port_ok {
        Ok(())
    } else {
        Err(format!(
            "{origin:?} must look like https://host[:port], with no path or trailing slash"
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    const APP_ID: &str = "1:123456789012:android:0123abcd";

    fn production() -> Vec<(&'static str, &'static str)> {
        vec![
            ("RUNNER_ENV", "production"),
            ("RUNNER_ADDR", "127.0.0.1:8080"),
            ("RUNNER_DOCKER_RUNTIME", "runsc"),
            ("RUNNER_TRUSTED_PROXIES", "127.0.0.1/32,::1/128"),
            ("RUNNER_ALLOWED_ORIGINS", "https://app.example.com"),
            ("RUNNER_FIREBASE_PROJECT_NUMBER", "123456789012"),
            ("RUNNER_FIREBASE_PROJECT_ID", "my-project-1"),
            ("RUNNER_APP_CHECK_APP_IDS", APP_ID),
        ]
    }

    fn with(
        base: &[(&'static str, &'static str)],
        extra: &[(&'static str, &'static str)],
    ) -> HashMap<String, String> {
        let mut m = map(base);
        for (k, v) in extra {
            m.insert(k.to_string(), v.to_string());
        }
        m
    }

    fn errors_of(vars: &HashMap<String, String>) -> String {
        Config::from_env_map(vars).unwrap_err().join("\n")
    }

    #[test]
    fn inflight_caps_are_validated() {
        let base = production();
        for (k, v) in [
            ("RUNNER_MAX_INFLIGHT_PER_CLIENT", "0"),
            ("RUNNER_MAX_INFLIGHT_PER_CLIENT", "101"),
            ("RUNNER_MAX_INFLIGHT_PER_VERIFIED_IP", "0"),
            ("RUNNER_MAX_INFLIGHT_PER_VERIFIED_IP", "1001"),
        ] {
            assert!(
                errors_of(&with(&base, &[(k, v)])).contains("RUNNER_MAX_INFLIGHT"),
                "{k}={v}"
            );
        }
        // The IP cap may not be lower than the per-client cap.
        let e = errors_of(&with(&base, &[("RUNNER_MAX_INFLIGHT_PER_CLIENT", "5")]));
        assert!(e.contains("RUNNER_MAX_INFLIGHT_PER_VERIFIED_IP"), "{e}");
        let ok = Config::from_env_map(&with(
            &base,
            &[
                ("RUNNER_MAX_INFLIGHT_PER_CLIENT", "2"),
                ("RUNNER_MAX_INFLIGHT_PER_VERIFIED_IP", "6"),
            ],
        ))
        .unwrap();
        assert_eq!(
            (ok.max_inflight_per_client, ok.max_inflight_per_verified_ip),
            (2, 6)
        );
    }

    #[test]
    fn valid_production_config_is_accepted() {
        let cfg = Config::from_env_map(&map(&production())).unwrap();
        assert!(cfg.is_production());
        let ac = cfg.app_check.expect("App Check required by default");
        assert_eq!(ac.project_number, "123456789012");
        assert_eq!(ac.jwks_url, DEFAULT_JWKS_URL);
        assert_eq!(ac.app_ids, vec![APP_ID]);
        assert_eq!(cfg.log_format, LogFormat::Json);
        assert_eq!(cfg.rate.token.per_min, 20);
        assert_eq!(cfg.rate.ip.per_hour, 3000);
        assert_eq!(cfg.max_queued, 16);
        assert_eq!(cfg.max_inflight_per_client, 1);
        assert_eq!(cfg.max_inflight_per_verified_ip, 4);
    }

    #[test]
    fn production_with_nothing_set_lists_every_missing_item() {
        let e = errors_of(&HashMap::new());
        for needle in [
            "RUNNER_ADDR",
            "RUNNER_DOCKER_RUNTIME",
            "RUNNER_TRUSTED_PROXIES",
            "RUNNER_ALLOWED_ORIGINS",
            "RUNNER_FIREBASE_PROJECT_NUMBER",
            "RUNNER_APP_CHECK_APP_IDS",
        ] {
            assert!(e.contains(needle), "missing {needle} in:\n{e}");
        }
    }

    #[test]
    fn production_rejects_unsafe_settings() {
        let base = production();
        assert!(
            errors_of(&with(&base, &[("RUNNER_APP_CHECK", "off")])).contains("RUNNER_APP_CHECK")
        );
        assert!(errors_of(&with(&base, &[("RUNNER_ALLOWED_ORIGINS", "*")])).contains("`*`"));
        assert!(errors_of(&with(&base, &[("RUNNER_ADDR", "0.0.0.0:8080")])).contains("loopback"));
        assert!(errors_of(&with(&base, &[("RUNNER_DOCKER_RUNTIME", "runc")])).contains("runsc"));
        assert!(
            errors_of(&with(&base, &[("RUNNER_ALLOW_RUNC", "1")])).contains("RUNNER_ALLOW_RUNC")
        );
        assert!(errors_of(&with(&base, &[("RUNNER_SANDBOX", "local")])).contains("unsandboxed"));
        assert!(errors_of(&with(&base, &[("RUNNER_LIMIT_IP_PER_MIN", "0")])).contains("above 0"));
        assert!(
            errors_of(&with(&base, &[("RUNNER_LIMIT_TOKEN_PER_HOUR", "0")])).contains("above 0")
        );
        assert!(
            errors_of(&with(
                &base,
                &[("RUNNER_APP_CHECK_JWKS_URL", "https://evil.example/jwks")]
            ))
            .contains("default")
        );
        assert!(
            errors_of(&with(
                &base,
                &[("RUNNER_ALLOWED_ORIGINS", "http://app.example.com")]
            ))
            .contains("https://host")
        );
        assert!(errors_of(&with(&base, &[("RUNNER_ENV", "staging")])).contains("RUNNER_ENV"));
    }

    #[test]
    fn lists_that_parse_to_nothing_are_errors_in_production() {
        let base = production();
        for value in [",", " , ,", ""] {
            let e = errors_of(&with(&base, &[("RUNNER_TRUSTED_PROXIES", value)]));
            assert!(e.contains("RUNNER_TRUSTED_PROXIES"), "{value:?}: {e}");
            let e = errors_of(&with(&base, &[("RUNNER_APP_CHECK_APP_IDS", value)]));
            assert!(e.contains("RUNNER_APP_CHECK_APP_IDS"), "{value:?}: {e}");
        }
        // A real entry next to the commas is fine.
        let ok = with(
            &base,
            &[
                ("RUNNER_TRUSTED_PROXIES", ",127.0.0.1/32,"),
                (
                    "RUNNER_APP_CHECK_APP_IDS",
                    ", ,1:123456789012:ios:0123abcd,",
                ),
            ],
        );
        let cfg = Config::from_env_map(&ok).unwrap();
        assert!(cfg.trusted_proxies.contains("127.0.0.1".parse().unwrap()));
        assert_eq!(cfg.app_check.unwrap().app_ids.len(), 1);
    }

    #[test]
    fn malformed_values_are_errors() {
        let base = production();
        assert!(
            errors_of(&with(
                &base,
                &[("RUNNER_APP_CHECK_APP_IDS", "1:2:linux:abc")]
            ))
            .contains("malformed app ID")
        );
        assert!(
            errors_of(&with(&base, &[("RUNNER_APP_CHECK_APP_IDS", "1:2:web:XYZ")]))
                .contains("malformed app ID")
        );
        assert!(
            errors_of(&with(&base, &[("RUNNER_FIREBASE_PROJECT_NUMBER", "12ab")]))
                .contains("digits")
        );
        assert!(
            errors_of(&with(&base, &[("RUNNER_FIREBASE_PROJECT_ID", "Bad_ID")]))
                .contains("PROJECT_ID")
        );
        assert!(
            errors_of(&with(&base, &[("RUNNER_TRUSTED_PROXIES", "localhost")]))
                .contains("TRUSTED_PROXIES")
        );
        assert!(
            errors_of(&with(&base, &[("RUNNER_LIMIT_TOKEN_BURST", "50")]))
                .contains("must not exceed")
        );
        assert!(errors_of(&with(&base, &[("RUNNER_LIMIT_MAX_KEYS", "10")])).contains("MAX_KEYS"));
        assert!(errors_of(&with(&base, &[("RUNNER_MAX_QUEUED", "5000")])).contains("MAX_QUEUED"));
        assert!(
            errors_of(&with(&base, &[("RUNNER_MEMORY_MB", "256")]))
                .contains("memory must be at least")
        );
        assert!(
            errors_of(&with(
                &base,
                &[("RUNNER_ALLOWED_ORIGINS", "https://a.example/path")]
            ))
            .contains("no path")
        );
    }

    #[test]
    fn development_with_nothing_set_needs_only_a_runtime_choice() {
        let m = map(&[("RUNNER_ENV", "development"), ("RUNNER_ALLOW_RUNC", "1")]);
        let cfg = Config::from_env_map(&m).unwrap();
        assert!(!cfg.is_production());
        assert!(cfg.app_check.is_none(), "App Check is off in development");
        assert_eq!(cfg.log_format, LogFormat::Text);
        assert_eq!(cfg.addr.to_string(), "0.0.0.0:8080");
        assert!(cfg.allowed_origins.is_empty());
        // Without either choice it still refuses, as before.
        let e = errors_of(&map(&[("RUNNER_ENV", "development")]));
        assert!(e.contains("RUNNER_ALLOW_RUNC"));
    }

    #[test]
    fn development_allows_local_sandbox_http_origins_and_disabled_limits() {
        let m = map(&[
            ("RUNNER_ENV", "development"),
            ("RUNNER_SANDBOX", "local"),
            ("RUNNER_ALLOWED_ORIGINS", "http://localhost:3000, *"),
            ("RUNNER_LIMIT_IP_PER_MIN", "0"),
            ("RUNNER_LIMIT_IP_BURST", "0"),
            ("RUNNER_LIMIT_IP_PER_HOUR", "0"),
        ]);
        let cfg = Config::from_env_map(&m).unwrap();
        assert_eq!(cfg.sandbox, SandboxChoice::Local);
        assert_eq!(cfg.rate.ip, BucketConfig::OFF);
        assert_eq!(cfg.allowed_origins.len(), 2);
    }

    #[test]
    fn development_can_still_require_app_check() {
        let m = map(&[
            ("RUNNER_ENV", "development"),
            ("RUNNER_SANDBOX", "local"),
            ("RUNNER_APP_CHECK", "required"),
        ]);
        let e = errors_of(&m);
        assert!(e.contains("PROJECT_NUMBER") && e.contains("APP_IDS"), "{e}");
        let m = map(&[
            ("RUNNER_ENV", "development"),
            ("RUNNER_SANDBOX", "local"),
            ("RUNNER_APP_CHECK", "required"),
            ("RUNNER_FIREBASE_PROJECT_NUMBER", "42"),
            ("RUNNER_APP_CHECK_APP_IDS", APP_ID),
            ("RUNNER_APP_CHECK_JWKS_URL", "http://127.0.0.1:9999/jwks"),
        ]);
        let cfg = Config::from_env_map(&m).unwrap();
        assert_eq!(
            cfg.app_check.unwrap().jwks_url,
            "http://127.0.0.1:9999/jwks"
        );
    }

    #[test]
    fn empty_values_count_as_unset() {
        let mut m = map(&production());
        m.insert("RUNNER_ALLOW_RUNC".into(), String::new());
        m.insert("RUNNER_LOG_FORMAT".into(), "  ".into());
        assert!(Config::from_env_map(&m).is_ok());
    }

    #[test]
    fn existing_settings_keep_working() {
        let mut m = map(&production());
        m.extend(map(&[
            ("RUNNER_MAX_JOBS", "2"),
            ("RUNNER_QUEUE_TIMEOUT_SECS", "7"),
            ("RUNNER_RUN_TIMEOUT_SECS", "3"),
            ("RUNNER_MEMORY_MB", "1024"),
            ("RUNNER_IMAGE", "example/img@sha256:abc"),
        ]));
        let cfg = Config::from_env_map(&m).unwrap();
        assert_eq!(cfg.max_jobs, 2);
        assert_eq!(cfg.queue_timeout, Duration::from_secs(7));
        assert_eq!(cfg.limits.run_timeout, Duration::from_secs(3));
        assert_eq!(cfg.limits.memory_mb, 1024);
        assert_eq!(
            cfg.sandbox,
            SandboxChoice::Docker {
                image: "example/img@sha256:abc".into(),
                runtime: Some("runsc".into())
            }
        );
        let bad = with(
            &production(),
            &[("RUNNER_MAX_JOBS", "0"), ("RUNNER_RUN_TIMEOUT_SECS", "x")],
        );
        let e = errors_of(&bad);
        assert!(
            e.contains("RUNNER_MAX_JOBS") && e.contains("RUNNER_RUN_TIMEOUT_SECS"),
            "{e}"
        );
    }

    #[test]
    fn helper_formats() {
        assert!(valid_project_id("my-project-1"));
        assert!(!valid_project_id("1abcde"));
        assert!(!valid_project_id("abcd"));
        assert!(valid_app_id("1:123:ios:ab12"));
        assert!(!valid_app_id("1:123:ios:"));
        assert!(check_origin("https://app.example.com:8443", false).is_ok());
        assert!(check_origin("https://app.example.com/", false).is_err());
        assert!(check_origin("http://localhost:3000", true).is_ok());
    }
}
