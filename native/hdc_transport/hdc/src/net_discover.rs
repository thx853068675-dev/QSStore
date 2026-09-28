//! UDP broadcast discovery for HDC network (wireless) devices.
//!
//! The device daemon listens on UDP port DEFAULT_PORT and replies to
//! `HANDSHAKE_MESSAGE` with `HANDSHAKE_MESSAGE-<tcp_listen_port>`. The host
//! then connects to the device IP on that TCP port.

use hdc_protocol::config::{HANDSHAKE_MESSAGE, SERVER_DEFAULT_PORT};
use std::collections::HashSet;
use std::io::{self, Error, ErrorKind};
use std::net::{IpAddr, SocketAddr};
use tokio::net::UdpSocket;
use tokio::time::{timeout, Duration};
use tracing::warn;

const DISCOVER_TIMEOUT_MS: u64 = 1000;
const RECV_BUF_SIZE: usize = 256;

fn format_daemon_addr(ip: &IpAddr, port: u16) -> String {
    match ip {
        IpAddr::V4(_) => format!("{}:{}", ip, port),
        IpAddr::V6(_) => format!("[{}]:{}", ip, port),
    }
}

fn parse_daemon_response(text: &str) -> Option<u16> {
    let prefix = format!("{}-", HANDSHAKE_MESSAGE);
    if !text.starts_with(&prefix) {
        return None;
    }
    text[prefix.len()..].trim().parse().ok()
}

/// Heuristic to find the local IPv4 address used for outbound traffic.
/// Connecting a UDP socket to a public address (without sending data) lets the
/// OS choose the best local route and reveals the local IP.
async fn local_ipv4_for_discovery() -> Option<IpAddr> {
    let probe = UdpSocket::bind("0.0.0.0:0").await.ok()?;
    // 8.8.8.8:53 is only used to resolve the local route; no packet is sent.
    probe.connect("8.8.8.8:53").await.ok()?;
    probe.local_addr().ok().map(|a| a.ip())
}

/// Build a set of broadcast addresses to probe: the global broadcast plus
/// directed broadcasts for the local IPv4 network (/24, /16, /8).
fn broadcast_addresses(local_ip: Option<IpAddr>) -> Vec<SocketAddr> {
    let mut addrs = vec![SocketAddr::from(([255, 255, 255, 255], SERVER_DEFAULT_PORT))];
    if let Some(IpAddr::V4(ip)) = local_ip {
        let o = ip.octets();
        addrs.push(SocketAddr::from(([o[0], o[1], o[2], 255], SERVER_DEFAULT_PORT)));
        addrs.push(SocketAddr::from(([o[0], o[1], 255, 255], SERVER_DEFAULT_PORT)));
        addrs.push(SocketAddr::from(([o[0], 255, 255, 255], SERVER_DEFAULT_PORT)));
    }
    addrs
}

/// Build a list of unicast addresses for the local /24 subnet. This is used as
/// a fallback when broadcast packets are dropped by the access point or host
/// firewall (common on Windows Wi-Fi adapters).
fn subnet_unicast_hosts(local_ip: Option<IpAddr>) -> Vec<SocketAddr> {
    let mut addrs = Vec::new();
    if let Some(IpAddr::V4(ip)) = local_ip {
        let o = ip.octets();
        for i in 1..=254 {
            addrs.push(SocketAddr::from(([o[0], o[1], o[2], i], SERVER_DEFAULT_PORT)));
        }
    }
    addrs
}

/// Broadcast a discovery request and return a list of discovered device
/// addresses in the form `ip:port` (or `[ipv6]:port`).
pub async fn discover_devices() -> io::Result<Vec<String>> {
    let bind_addr = SocketAddr::from(([0, 0, 0, 0], SERVER_DEFAULT_PORT));
    let socket = UdpSocket::bind(bind_addr).await.map_err(|e| {
        Error::new(
            ErrorKind::AddrInUse,
            format!("Failed to bind UDP discovery socket on port {SERVER_DEFAULT_PORT}: {e}"),
        )
    })?;
    socket.set_broadcast(true).map_err(|e| {
        Error::new(ErrorKind::Other, format!("Failed to enable UDP broadcast: {e}"))
    })?;

    let local_ip = local_ipv4_for_discovery().await;

    // 1) Try standard broadcasts first.
    for target in broadcast_addresses(local_ip) {
        if let Err(e) = socket.send_to(HANDSHAKE_MESSAGE.as_bytes(), target).await {
            warn!("Failed to send discovery broadcast to {target}: {e}");
        }
    }

    // 2) Fallback: probe every host on the local /24 subnet. Many consumer APs
    // and Windows Wi-Fi adapters silently drop broadcast UDP, but unicast UDP
    // to each host on the same subnet is usually allowed.
    for target in subnet_unicast_hosts(local_ip) {
        if let Err(e) = socket.send_to(HANDSHAKE_MESSAGE.as_bytes(), target).await {
            warn!("Failed to send discovery unicast to {target}: {e}");
        }
    }

    let mut found = Vec::new();
    let mut seen = HashSet::new();
    let deadline = tokio::time::Instant::now() + Duration::from_millis(DISCOVER_TIMEOUT_MS);

    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }

        let mut buf = [0u8; RECV_BUF_SIZE];
        match timeout(remaining, socket.recv_from(&mut buf)).await {
            Ok(Ok((len, peer))) => {
                let text = String::from_utf8_lossy(&buf[..len]);
                if let Some(port) = parse_daemon_response(&text) {
                    let addr = format_daemon_addr(&peer.ip(), port);
                    if seen.insert(addr.clone()) {
                        found.push(addr);
                    }
                }
            }
            Ok(Err(_)) => break,
            Err(_) => break,
        }
    }

    Ok(found)
}
