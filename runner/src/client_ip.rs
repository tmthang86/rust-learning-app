//! Finding the real client address behind a reverse proxy.
//!
//! The runner sits behind Caddy on the same machine. When Caddy gets a
//! request from an untrusted client it deletes any incoming
//! `X-Forwarded-For` and sets it to the client's real address, so the
//! rightmost entry is trustworthy. A request that reaches the runner
//! directly from anywhere else is not trusted to say who it is for.

use std::net::IpAddr;

use axum::http::{HeaderMap, HeaderName};

const XFF: HeaderName = HeaderName::from_static("x-forwarded-for");

/// One network in CIDR notation, e.g. `127.0.0.1/32` or `::1/128`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cidr {
    network: IpAddr,
    prefix: u8,
}

impl Cidr {
    pub fn parse(text: &str) -> Result<Self, String> {
        let text = text.trim();
        let (addr, prefix) = match text.split_once('/') {
            Some((a, p)) => (a, Some(p)),
            None => (text, None),
        };
        let network: IpAddr = addr
            .parse()
            .map_err(|_| format!("{text:?} is not an IP address or CIDR range"))?;
        let max = if network.is_ipv4() { 32 } else { 128 };
        let prefix = match prefix {
            Some(p) => p
                .parse::<u8>()
                .ok()
                .filter(|p| *p <= max)
                .ok_or_else(|| format!("{text:?} has an invalid prefix length"))?,
            None => max,
        };
        Ok(Self {
            network: canonical(network),
            prefix,
        })
    }

    pub fn contains(&self, ip: IpAddr) -> bool {
        match (self.network, canonical(ip)) {
            (IpAddr::V4(net), IpAddr::V4(ip)) => {
                let mask = mask32(self.prefix);
                u32::from(net) & mask == u32::from(ip) & mask
            }
            (IpAddr::V6(net), IpAddr::V6(ip)) => {
                let mask = mask128(self.prefix);
                u128::from(net) & mask == u128::from(ip) & mask
            }
            _ => false,
        }
    }
}

fn mask32(prefix: u8) -> u32 {
    if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - u32::from(prefix))
    }
}

fn mask128(prefix: u8) -> u128 {
    if prefix == 0 {
        0
    } else {
        u128::MAX << (128 - u32::from(prefix))
    }
}

/// `::ffff:1.2.3.4` is the same peer as `1.2.3.4`.
fn canonical(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(IpAddr::V6(v6), IpAddr::V4),
        v4 => v4,
    }
}

/// The proxies whose `X-Forwarded-For` header is believed.
#[derive(Debug, Clone, Default)]
pub struct TrustedProxies(Vec<Cidr>);

impl TrustedProxies {
    pub fn new(ranges: Vec<Cidr>) -> Self {
        Self(ranges)
    }

    /// Parses a comma-separated CIDR list. Reports every bad entry.
    pub fn parse(list: &str) -> Result<Self, Vec<String>> {
        let mut ranges = Vec::new();
        let mut errors = Vec::new();
        for item in list.split(',').map(str::trim).filter(|i| !i.is_empty()) {
            match Cidr::parse(item) {
                Ok(c) => ranges.push(c),
                Err(e) => errors.push(e),
            }
        }
        if errors.is_empty() {
            Ok(Self(ranges))
        } else {
            Err(errors)
        }
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn contains(&self, ip: IpAddr) -> bool {
        self.0.iter().any(|c| c.contains(ip))
    }
}

/// Where the client address came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IpSource {
    /// The TCP peer itself (not a trusted proxy).
    Peer,
    /// An `X-Forwarded-For` entry set by a trusted proxy.
    Forwarded,
    /// The peer is trusted but sent no usable `X-Forwarded-For`.
    PeerFallback,
}

/// The client's address.
///
/// If the TCP peer is not a trusted proxy, `X-Forwarded-For` is ignored and
/// the peer is the client. If it is, all `X-Forwarded-For` values are joined
/// and walked from the right, skipping trusted proxies; the first entry that
/// parses as an address is the client. With none, the peer is used.
pub fn client_ip(
    peer: IpAddr,
    headers: &HeaderMap,
    trusted: &TrustedProxies,
) -> (IpAddr, IpSource) {
    let peer = canonical(peer);
    if !trusted.contains(peer) {
        return (peer, IpSource::Peer);
    }
    let joined = headers
        .get_all(XFF)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .collect::<Vec<_>>()
        .join(",");
    for entry in joined.rsplit(',') {
        let Ok(ip) = entry.trim().parse::<IpAddr>() else {
            continue;
        };
        let ip = canonical(ip);
        if !trusted.contains(ip) {
            return (ip, IpSource::Forwarded);
        }
    }
    (peer, IpSource::PeerFallback)
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    fn proxies() -> TrustedProxies {
        TrustedProxies::parse("127.0.0.1/32,::1/128").unwrap()
    }

    fn headers(values: &[&str]) -> HeaderMap {
        let mut h = HeaderMap::new();
        for v in values {
            h.append("x-forwarded-for", HeaderValue::from_str(v).unwrap());
        }
        h
    }

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    #[test]
    fn untrusted_peer_cannot_spoof() {
        let (got, src) = client_ip(ip("203.0.113.9"), &headers(&["1.2.3.4"]), &proxies());
        assert_eq!(got, ip("203.0.113.9"));
        assert_eq!(src, IpSource::Peer);
    }

    #[test]
    fn trusted_peer_gives_the_rightmost_entry() {
        let h = headers(&["198.51.100.7"]);
        assert_eq!(
            client_ip(ip("127.0.0.1"), &h, &proxies()).0,
            ip("198.51.100.7")
        );
        // Anything the client prepended on the left is ignored.
        let h = headers(&["6.6.6.6, 198.51.100.7"]);
        assert_eq!(
            client_ip(ip("127.0.0.1"), &h, &proxies()).0,
            ip("198.51.100.7")
        );
    }

    #[test]
    fn trusted_entries_are_skipped() {
        let h = headers(&["198.51.100.7, 127.0.0.1, ::1"]);
        assert_eq!(client_ip(ip("::1"), &h, &proxies()).0, ip("198.51.100.7"));
    }

    #[test]
    fn garbage_falls_back_to_the_peer() {
        let h = headers(&["not-an-ip, also bad"]);
        let (got, src) = client_ip(ip("127.0.0.1"), &h, &proxies());
        assert_eq!(got, ip("127.0.0.1"));
        assert_eq!(src, IpSource::PeerFallback);
        let (got, _) = client_ip(ip("127.0.0.1"), &HeaderMap::new(), &proxies());
        assert_eq!(got, ip("127.0.0.1"));
    }

    #[test]
    fn multiple_headers_are_joined() {
        let h = headers(&["6.6.6.6", "198.51.100.7"]);
        assert_eq!(
            client_ip(ip("127.0.0.1"), &h, &proxies()).0,
            ip("198.51.100.7")
        );
        let h = headers(&["198.51.100.7", "127.0.0.1"]);
        assert_eq!(
            client_ip(ip("127.0.0.1"), &h, &proxies()).0,
            ip("198.51.100.7")
        );
    }

    #[test]
    fn mapped_ipv6_peer_counts_as_ipv4() {
        let h = headers(&["198.51.100.7"]);
        let got = client_ip(ip("::ffff:127.0.0.1"), &h, &proxies()).0;
        assert_eq!(got, ip("198.51.100.7"));
    }

    #[test]
    fn cidr_parsing_and_matching() {
        let c = Cidr::parse("10.0.0.0/8").unwrap();
        assert!(c.contains(ip("10.9.9.9")));
        assert!(!c.contains(ip("11.0.0.1")));
        assert!(Cidr::parse("0.0.0.0/0").unwrap().contains(ip("8.8.8.8")));
        assert!(Cidr::parse("10.0.0.0/33").is_err());
        assert!(Cidr::parse("nope").is_err());
        assert!(Cidr::parse("fd00::/8").unwrap().contains(ip("fd12::1")));
        assert!(TrustedProxies::parse("127.0.0.1/32, bogus").is_err());
        assert!(TrustedProxies::parse("").unwrap().is_empty());
    }
}
