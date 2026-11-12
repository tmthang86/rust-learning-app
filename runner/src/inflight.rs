//! Caps how many jobs one client may have running or queued at once.
//!
//! The rate limits count requests over time. They can't stop one client from
//! keeping both job slots busy: a loop that runs until the 5 s timeout costs
//! far more slot time than the request count suggests. So each client IP and
//! each App Check token (by the same HMAC the token limiter uses) may hold
//! only [`InFlight::cap`] requests between the gate and the answer. The next
//! one gets an immediate 429 `client_busy`. A real learner runs one program
//! at a time, so this costs them nothing.
//!
//! The cap counts a request from the moment the gate lets it in until its
//! response is built, which includes the time spent waiting for a slot. The
//! guard is released on every path, including the client disconnecting
//! (axum drops the handler's future, and with it the guard).
//!
//! Many learners can sit behind one address (a mobile carrier's NAT, a
//! school), so a request with a *verified* App Check token is counted
//! against a higher per-IP cap (`RUNNER_MAX_INFLIGHT_PER_VERIFIED_IP`, 4 by
//! default) while each token still holds one place. Requests without a
//! verified token (App Check off, development) keep the low per-IP cap.
//! Residual risk: with the defaults (4 per verified IP, 2 workers) one
//! address with two valid tokens can hold every worker, and others then get
//! 503 `busy` once the queue timeout passes. Only the per-IP rate buckets
//! limit an attacker who rotates tokens. main.rs warns about this at start.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Arc, Mutex};

/// Seconds a rejected client is told to wait.
pub const RETRY_AFTER_SECS: u64 = 2;

/// Which cap said no, for the log.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    Ip,
    Token,
}

impl Scope {
    pub fn as_str(self) -> &'static str {
        match self {
            Scope::Ip => "inflight_ip",
            Scope::Token => "inflight_token",
        }
    }
}

#[derive(Default)]
struct Counts {
    ips: HashMap<IpAddr, usize>,
    tokens: HashMap<[u8; 32], usize>,
}

pub struct InFlight {
    /// Per token, and per IP for requests without a verified token.
    cap: usize,
    /// Per IP for requests that carry a verified App Check token. Higher,
    /// because a verified request costs the attacker an attestation and
    /// many real learners can sit behind one carrier-grade NAT address.
    verified_ip_cap: usize,
    counts: Mutex<Counts>,
}

impl InFlight {
    /// One cap for everything.
    pub fn new(cap: usize) -> Arc<Self> {
        Self::with_verified_ip_cap(cap, cap)
    }

    /// `cap` per token and per unverified IP; `verified_ip_cap` per IP for
    /// requests with a verified token (at least `cap`).
    pub fn with_verified_ip_cap(cap: usize, verified_ip_cap: usize) -> Arc<Self> {
        Arc::new(Self {
            cap,
            verified_ip_cap: verified_ip_cap.max(cap),
            counts: Mutex::default(),
        })
    }

    pub fn cap(&self) -> usize {
        self.cap
    }

    /// Takes one place for `ip` and, when given, `token`. Both caps are
    /// checked before either count changes, so a rejection leaves no trace.
    pub fn try_acquire(
        self: &Arc<Self>,
        ip: IpAddr,
        token: Option<[u8; 32]>,
    ) -> Result<Guard, Scope> {
        // A poisoned lock only means another request panicked; the counts
        // are plain integers and still right.
        let mut c = self.counts.lock().unwrap_or_else(|e| e.into_inner());
        let ip_cap = if token.is_some() {
            self.verified_ip_cap
        } else {
            self.cap
        };
        if c.ips.get(&ip).copied().unwrap_or(0) >= ip_cap {
            return Err(Scope::Ip);
        }
        if let Some(t) = &token
            && c.tokens.get(t).copied().unwrap_or(0) >= self.cap
        {
            return Err(Scope::Token);
        }
        *c.ips.entry(ip).or_insert(0) += 1;
        if let Some(t) = token {
            *c.tokens.entry(t).or_insert(0) += 1;
        }
        Ok(Guard {
            owner: self.clone(),
            ip,
            token,
        })
    }

    /// Clients holding a place right now (for tests and the summary).
    pub fn active_ips(&self) -> usize {
        self.counts
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .ips
            .len()
    }
}

/// A place held by one request. Dropping it gives the place back.
pub struct Guard {
    owner: Arc<InFlight>,
    ip: IpAddr,
    token: Option<[u8; 32]>,
}

impl Drop for Guard {
    fn drop(&mut self) {
        let mut c = self.owner.counts.lock().unwrap_or_else(|e| e.into_inner());
        release(&mut c.ips, &self.ip);
        if let Some(t) = &self.token {
            release(&mut c.tokens, t);
        }
    }
}

/// Counts go back to zero by removing the key, so the maps hold only
/// clients with a request in flight and never grow with traffic.
fn release<K: std::hash::Hash + Eq>(map: &mut HashMap<K, usize>, key: &K) {
    if let Some(n) = map.get_mut(key) {
        *n -= 1;
        if *n == 0 {
            map.remove(key);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    #[test]
    fn second_request_from_one_ip_is_refused_until_the_first_ends() {
        let f = InFlight::new(1);
        let a = f.try_acquire(ip("198.51.100.1"), None).unwrap();
        assert_eq!(
            f.try_acquire(ip("198.51.100.1"), None).err(),
            Some(Scope::Ip)
        );
        // Another IP is not affected.
        let _b = f.try_acquire(ip("198.51.100.2"), None).unwrap();
        drop(a);
        assert!(f.try_acquire(ip("198.51.100.1"), None).is_ok());
    }

    #[test]
    fn a_token_is_capped_across_different_ips() {
        let f = InFlight::new(1);
        let t = [7u8; 32];
        let _a = f.try_acquire(ip("198.51.100.1"), Some(t)).unwrap();
        assert_eq!(
            f.try_acquire(ip("198.51.100.2"), Some(t)).err(),
            Some(Scope::Token)
        );
        assert!(f.try_acquire(ip("198.51.100.2"), Some([8u8; 32])).is_ok());
    }

    #[test]
    fn a_refusal_leaves_no_count_behind() {
        let f = InFlight::new(1);
        let t = [1u8; 32];
        let a = f.try_acquire(ip("198.51.100.1"), Some(t)).unwrap();
        // Refused on the token; the new IP must not stay counted.
        assert!(f.try_acquire(ip("198.51.100.9"), Some(t)).is_err());
        assert!(f.try_acquire(ip("198.51.100.9"), None).is_ok());
        drop(a);
        assert_eq!(f.active_ips(), 0);
    }

    #[test]
    fn verified_requests_get_a_higher_ip_cap_but_one_per_token() {
        let f = InFlight::with_verified_ip_cap(1, 3);
        let nat = ip("198.51.100.1");
        let _a = f.try_acquire(nat, Some([1u8; 32])).unwrap();
        let _b = f.try_acquire(nat, Some([2u8; 32])).unwrap();
        let _c = f.try_acquire(nat, Some([3u8; 32])).unwrap();
        // The IP is full for verified requests...
        assert_eq!(f.try_acquire(nat, Some([4u8; 32])).err(), Some(Scope::Ip));
        // ...and a token still counts once.
        assert_eq!(
            f.try_acquire(ip("198.51.100.2"), Some([1u8; 32])).err(),
            Some(Scope::Token)
        );
    }

    #[test]
    fn requests_without_a_token_keep_the_low_ip_cap() {
        let f = InFlight::with_verified_ip_cap(1, 4);
        let _a = f.try_acquire(ip("198.51.100.1"), None).unwrap();
        assert_eq!(
            f.try_acquire(ip("198.51.100.1"), None).err(),
            Some(Scope::Ip)
        );
    }

    #[test]
    fn the_cap_can_be_raised() {
        let f = InFlight::new(2);
        let _a = f.try_acquire(ip("198.51.100.1"), None).unwrap();
        let _b = f.try_acquire(ip("198.51.100.1"), None).unwrap();
        assert!(f.try_acquire(ip("198.51.100.1"), None).is_err());
    }

    #[test]
    fn maps_do_not_grow_with_traffic() {
        let f = InFlight::new(1);
        for n in 0..100u8 {
            let g = f.try_acquire(ip(&format!("198.51.100.{n}")), Some([n; 32]));
            drop(g);
        }
        assert_eq!(f.active_ips(), 0);
        assert!(f.counts.lock().unwrap().tokens.is_empty());
    }
}
