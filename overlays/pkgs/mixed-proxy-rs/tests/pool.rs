use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use tokio::net::UdpSocket;

use super::bind;
use crate::config::PortRange;

#[tokio::test]
async fn scans_full_range_when_only_port_after_32_is_available() {
    // Given all 128 ports held on an isolated loopback address.
    let ip = IpAddr::V4(Ipv4Addr::new(127, 0, 0, 4));
    let range: PortRange = serde_json::from_str(r#"{"from":20000,"to":20127}"#).unwrap();
    let mut held = Vec::new();
    for port in 20000..=20127 {
        match UdpSocket::bind(SocketAddr::new(ip, port)).await {
            Ok(socket) => held.push(socket),
            Err(error) if error.kind() == std::io::ErrorKind::AddrInUse => (),
            Err(error) => panic!("{error}"),
        }
    }
    // When only port 20097 is released and an association allocates.
    let index = held
        .iter()
        .position(|socket| socket.local_addr().unwrap().port() == 20097)
        .unwrap();
    drop(held.remove(index));
    let relay = bind(ip, &range).await.unwrap();
    // Then the entire numeric range is searched without a 32-attempt cutoff.
    assert_eq!(relay.local_addr().unwrap(), SocketAddr::new(ip, 20097));
}

#[tokio::test]
async fn refuses_fallback_when_entire_range_is_held() {
    // Given an entire pool occupied on a distinct loopback address.
    let ip = IpAddr::V4(Ipv4Addr::new(127, 0, 0, 5));
    let range: PortRange = serde_json::from_str(r#"{"from":20000,"to":20127}"#).unwrap();
    let mut held = Vec::new();
    for port in 20000..=20127 {
        match UdpSocket::bind(SocketAddr::new(ip, port)).await {
            Ok(socket) => held.push(socket),
            Err(error) if error.kind() == std::io::ErrorKind::AddrInUse => (),
            Err(error) => panic!("{error}"),
        }
    }
    // When a relay tries to allocate.
    let result = bind(ip, &range).await;
    // Then no ephemeral fallback escapes the pool.
    assert_eq!(result.unwrap_err().kind(), std::io::ErrorKind::AddrInUse);
    drop(held);
}
