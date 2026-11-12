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
//! Tradeoff: many learners behind one address (a mobile carrier's NAT, a
//! school) share the per-IP cap. Raise `RUNNER_MAX_INFLIGHT_PER_CLIENT` if
//! that shows up in the `limiter=inflight_ip` log counts.

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
    cap: usize,
    counts: Mutex<Counts>,
}

impl InFlight {
    pub fn new(cap: usize) -> Arc<Self> {
        Arc::new(Self {
            cap,
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
        if c.ips.get(&ip).copied().unwrap_or(0) >= self.cap {
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
