//! In-process rate limits (GCRA token buckets from `governor`).
//!
//! Two scopes, each with a short and an hourly bucket that must both allow
//! the request:
//!
//! - per client IP, checked before authentication;
//! - per App Check token (keyed by an HMAC of the token), checked after.
//!
//! There is a single runner process, so there is no external store; a
//! restart resets the counters. `governor` can't give a cell back when a
//! later bucket rejects, and that is accepted: a rejected request still
//! counted against the buckets checked before it.
//!
//! The hourly bucket is `Quota::per_hour(N)`, whose burst is N: the whole
//! hour's allowance is available at once and refills at N/60 per minute. The
//! short bucket smooths the rate within the hour.

use std::hash::Hash;
use std::net::IpAddr;
use std::num::NonZeroU32;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use governor::clock::{Clock, DefaultClock};
use governor::middleware::NoOpMiddleware;
use governor::nanos::Nanos;
use governor::state::StateStore;
use governor::state::keyed::{DashMapStateStore, ShrinkableKeyedStateStore};
use governor::{Quota, RateLimiter};

use crate::config::{BucketConfig, RateConfig};

/// Why a request was turned away.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rejection {
    /// Seconds until the request could succeed (`Retry-After`), at least 1.
    pub retry_after: u64,
    /// Which bucket said no, for the log.
    pub limiter: &'static str,
}

/// `Retry-After` when a limiter is full of keys and a new one arrives.
const KEY_CAP_RETRY_SECS: u64 = 60;

/// A keyed state store that stays reachable from outside the limiter, so
/// the key count and "is this key new" can be read.
struct Store<K: Hash + Eq + Clone>(Arc<DashMapStateStore<K>>);

impl<K: Hash + Eq + Clone> StateStore for Store<K> {
    type Key = K;

    fn measure_and_replace<T, F, E>(&self, key: &K, f: F) -> Result<T, E>
    where
        F: Fn(Option<Nanos>) -> Result<(T, Nanos), E>,
    {
        self.0.measure_and_replace(key, f)
    }
}

impl<K: Hash + Eq + Clone> ShrinkableKeyedStateStore<K> for Store<K> {
    fn retain_recent(&self, drop_below: Nanos) {
        ShrinkableKeyedStateStore::retain_recent(&*self.0, drop_below);
    }

    fn shrink_to_fit(&self) {
        ShrinkableKeyedStateStore::shrink_to_fit(&*self.0);
    }

    fn len(&self) -> usize {
        self.0.len()
    }

    fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

struct Bucket<K: Hash + Eq + Clone, C: Clock> {
    name: &'static str,
    limiter: RateLimiter<K, Store<K>, C, NoOpMiddleware<C::Instant>>,
    store: Arc<DashMapStateStore<K>>,
    clock: C,
}

impl<K: Hash + Eq + Clone, C: Clock + Clone> Bucket<K, C> {
    fn new(name: &'static str, quota: Quota, clock: C) -> Self {
        let store: Arc<DashMapStateStore<K>> = Arc::default();
        Self {
            name,
            limiter: RateLimiter::new(quota, Store(store.clone()), clock.clone()),
            store,
            clock,
        }
    }

    fn check(&self, key: &K, max_keys: usize) -> Result<(), Rejection> {
        if self.store.len() >= max_keys && !self.store.contains_key(key) {
            return Err(Rejection {
                retry_after: KEY_CAP_RETRY_SECS,
                limiter: self.name,
            });
        }
        self.limiter.check_key(key).map_err(|not_until| {
            let wait = not_until.wait_time_from(self.clock.now());
            Rejection {
                retry_after: wait.as_secs_f64().ceil().max(1.0) as u64,
                limiter: self.name,
            }
        })
    }

    fn cleanup(&self) {
        self.limiter.retain_recent();
        self.limiter.shrink_to_fit();
    }

    fn len(&self) -> usize {
        self.store.len()
    }
}

/// One scope (per IP, or per token): a short and an hourly bucket.
struct Scope<K: Hash + Eq + Clone, C: Clock> {
    short: Option<Bucket<K, C>>,
    long: Option<Bucket<K, C>>,
    max_keys: usize,
    /// When the key cap was last logged, to log it at most once a minute.
    cap_logged: Mutex<Option<Instant>>,
}

impl<K: Hash + Eq + Clone, C: Clock + Clone> Scope<K, C> {
    fn new(
        names: (&'static str, &'static str),
        cfg: BucketConfig,
        max_keys: usize,
        clock: C,
    ) -> Self {
        let short = NonZeroU32::new(cfg.per_min).map(|per_min| {
            // A zero burst can't be built; config validation rejects it.
            let burst = NonZeroU32::new(cfg.burst).unwrap_or(per_min).min(per_min);
            Bucket::new(
                names.0,
                Quota::per_minute(per_min).allow_burst(burst),
                clock.clone(),
            )
        });
        let long = NonZeroU32::new(cfg.per_hour)
            .map(|per_hour| Bucket::new(names.1, Quota::per_hour(per_hour), clock));
        Self {
            short,
            long,
            max_keys,
            cap_logged: Mutex::default(),
        }
    }

    fn check(&self, key: &K) -> Result<(), Rejection> {
        for bucket in [&self.short, &self.long].into_iter().flatten() {
            if let Err(rejection) = bucket.check(key, self.max_keys) {
                if rejection.retry_after == KEY_CAP_RETRY_SECS && bucket.len() >= self.max_keys {
                    self.log_cap(bucket.name);
                }
                return Err(rejection);
            }
        }
        Ok(())
    }

    fn log_cap(&self, limiter: &'static str) {
        let mut last = self.cap_logged.lock().unwrap();
        if last.is_none_or(|t| t.elapsed() >= Duration::from_secs(60)) {
            *last = Some(Instant::now());
            tracing::warn!(
                event = "limiter_key_cap",
                limiter,
                max_keys = self.max_keys,
                "rate limiter is full of keys: rejecting new ones"
            );
        }
    }

    fn cleanup(&self) {
        for bucket in [&self.short, &self.long].into_iter().flatten() {
            bucket.cleanup();
        }
    }

    fn keys(&self) -> usize {
        [&self.short, &self.long]
            .into_iter()
            .flatten()
            .map(Bucket::len)
            .max()
            .unwrap_or(0)
    }
}

/// All the runner's rate limits.
pub struct RateLimits<C: Clock + Clone = DefaultClock> {
    ip: Scope<IpAddr, C>,
    token: Scope<[u8; 32], C>,
}

impl RateLimits {
    pub fn new(cfg: RateConfig) -> Self {
        Self::with_clock(cfg, DefaultClock::default())
    }

    /// Every bucket off. For tests and development.
    pub fn disabled() -> Self {
        Self::new(RateConfig::OFF)
    }
}

impl<C: Clock + Clone> RateLimits<C> {
    pub fn with_clock(cfg: RateConfig, clock: C) -> Self {
        Self {
            ip: Scope::new(("ip_short", "ip_long"), cfg.ip, cfg.max_keys, clock.clone()),
            token: Scope::new(
                ("token_short", "token_long"),
                cfg.token,
                cfg.max_keys,
                clock,
            ),
        }
    }

    pub fn check_ip(&self, ip: IpAddr) -> Result<(), Rejection> {
        self.ip.check(&ip)
    }

    pub fn check_token(&self, key: &[u8; 32]) -> Result<(), Rejection> {
        self.token.check(key)
    }

    /// Drops idle keys and gives the memory back. Call it every minute.
    pub fn cleanup(&self) {
        self.ip.cleanup();
        self.token.cleanup();
    }

    /// Keys held per scope: (IP, token).
    pub fn key_counts(&self) -> (usize, usize) {
        (self.ip.keys(), self.token.keys())
    }
}

/// Runs [`RateLimits::cleanup`] every 60 seconds.
pub async fn cleanup_loop(state: Arc<crate::AppState>) {
    let mut tick = tokio::time::interval(Duration::from_secs(60));
    tick.tick().await;
    loop {
        tick.tick().await;
        state.rate.cleanup();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use governor::clock::FakeRelativeClock;

    fn cfg(token: BucketConfig, ip: BucketConfig, max_keys: usize) -> RateConfig {
        RateConfig {
            token,
            ip,
            max_keys,
        }
    }

    const OFF: BucketConfig = BucketConfig::OFF;

    fn ip(n: u8) -> IpAddr {
        IpAddr::from([10, 0, 0, n])
    }

    fn key(n: u8) -> [u8; 32] {
        [n; 32]
    }

    fn limiter(
        token: BucketConfig,
        max_keys: usize,
    ) -> (RateLimits<FakeRelativeClock>, FakeRelativeClock) {
        let clock = FakeRelativeClock::default();
        (
            RateLimits::with_clock(cfg(token, OFF, max_keys), clock.clone()),
            clock,
        )
    }

    #[test]
    fn burst_then_reject_with_retry_after() {
        // 6/min = one cell every 10 s, burst 3.
        let token = BucketConfig {
            per_min: 6,
            burst: 3,
            per_hour: 1000,
        };
        let (rl, clock) = limiter(token, 1000);
        for _ in 0..3 {
            assert!(rl.check_token(&key(1)).is_ok());
        }
        let r = rl.check_token(&key(1)).unwrap_err();
        assert_eq!(r.limiter, "token_short");
        assert_eq!(r.retry_after, 10);
        clock.advance(Duration::from_secs(4));
        assert_eq!(rl.check_token(&key(1)).unwrap_err().retry_after, 6);
        clock.advance(Duration::from_secs(6));
        assert!(rl.check_token(&key(1)).is_ok());
        // Another key is unaffected.
        assert!(rl.check_token(&key(2)).is_ok());
    }

    #[test]
    fn retry_after_is_at_least_one_second() {
        let token = BucketConfig {
            per_min: 60,
            burst: 1,
            per_hour: 1000,
        };
        let (rl, clock) = limiter(token, 1000);
        assert!(rl.check_token(&key(1)).is_ok());
        clock.advance(Duration::from_millis(100));
        let r = rl.check_token(&key(1)).unwrap_err();
        assert_eq!(r.retry_after, 1);
    }

    #[test]
    fn hourly_cap_bounds_the_sustained_rate() {
        // The hourly bucket's burst is its whole allowance (20), and it
        // refills at 20 per hour, however fast the short bucket would allow.
        let token = BucketConfig {
            per_min: 60,
            burst: 10,
            per_hour: 20,
        };
        let (rl, clock) = limiter(token, 1000);
        let mut allowed = 0;
        let mut first_rejection = None;
        // One request every 2 seconds for three hours is 5400 requests.
        for _ in 0..5400 {
            match rl.check_token(&key(1)) {
                Ok(()) => allowed += 1,
                Err(r) => first_rejection = first_rejection.or(Some(r)),
            }
            clock.advance(Duration::from_secs(2));
        }
        // The first 20 at once, then 20 more per hour (3 hours): 80.
        assert!((79..=81).contains(&allowed), "allowed {allowed}");
        let r = first_rejection.unwrap();
        assert_eq!(r.limiter, "token_long");
        // One hourly cell takes 180 s to refill; 20 requests took 40 s.
        assert!((130..=150).contains(&r.retry_after), "{r:?}");
    }

    #[test]
    fn key_cap_rejects_new_keys_but_not_existing_ones() {
        let token = BucketConfig {
            per_min: 60,
            burst: 60,
            per_hour: 1000,
        };
        let (rl, _clock) = limiter(token, 3);
        for n in 1..=3 {
            assert!(rl.check_token(&key(n)).is_ok());
        }
        let r = rl.check_token(&key(4)).unwrap_err();
        assert_eq!(r.retry_after, 60);
        assert_eq!(r.limiter, "token_short");
        assert!(
            rl.check_token(&key(2)).is_ok(),
            "existing keys keep working"
        );
        assert_eq!(rl.key_counts().1, 3);
    }

    #[test]
    fn retain_recent_drops_idle_keys() {
        let token = BucketConfig {
            per_min: 60,
            burst: 5,
            per_hour: 100,
        };
        let (rl, clock) = limiter(token, 1000);
        for n in 0..10 {
            rl.check_token(&key(n)).unwrap();
        }
        rl.cleanup();
        assert_eq!(rl.key_counts().1, 10, "recent keys stay");
        // Past both buckets' full-refill times (one hour for the hourly one).
        clock.advance(Duration::from_secs(3 * 3600));
        rl.cleanup();
        assert_eq!(rl.key_counts().1, 0);
        // A freed cap lets new keys in again.
        assert!(rl.check_token(&key(99)).is_ok());
    }

    #[test]
    fn ip_scope_is_separate_and_off_buckets_allow_everything() {
        let ipcfg = BucketConfig {
            per_min: 60,
            burst: 1,
            per_hour: 100,
        };
        let clock = FakeRelativeClock::default();
        let rl = RateLimits::with_clock(cfg(OFF, ipcfg, 100), clock);
        assert!(rl.check_ip(ip(1)).is_ok());
        assert_eq!(rl.check_ip(ip(1)).unwrap_err().limiter, "ip_short");
        assert!(rl.check_ip(ip(2)).is_ok());
        for _ in 0..1000 {
            assert!(rl.check_token(&key(1)).is_ok(), "token buckets are off");
        }
        assert_eq!(rl.key_counts().1, 0, "off buckets keep no keys");
        assert!(RateLimits::disabled().check_ip(ip(1)).is_ok());
    }
}
