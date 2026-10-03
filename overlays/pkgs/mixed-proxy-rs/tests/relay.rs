use super::{ClientEndpoint, packets, run};
use fast_socks5::{new_udp_header, parse_udp_request};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use tokio::{
    io::AsyncWriteExt,
    net::{TcpListener, TcpStream, UdpSocket},
    task::JoinSet,
    time::{Duration, timeout},
};

async fn control_pair() -> (TcpStream, TcpStream) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let client = TcpStream::connect(listener.local_addr().unwrap())
        .await
        .unwrap();
    let (server, _) = listener.accept().await.unwrap();
    (client, server)
}

#[test]
fn filters_by_ip_when_udp_port_differs_from_tcp_port() {
    let peer: SocketAddr = "127.0.0.1:44321".parse().unwrap();
    let mut endpoint = ClientEndpoint::new(peer, "0.0.0.0:0".parse().unwrap()).unwrap();
    assert!(endpoint.accepts("127.0.0.1:12345".parse().unwrap()));
    endpoint.pin(IpAddr::V4(Ipv4Addr::LOCALHOST));
    assert!(endpoint.accepts("127.0.0.1:54321".parse().unwrap()));
    assert!(!endpoint.accepts("127.0.0.2:44321".parse().unwrap()));
    assert!(ClientEndpoint::new(peer, "127.0.0.2:0".parse().unwrap()).is_err());
}

#[tokio::test]
async fn releases_socket_when_control_closes_before_first_packet() {
    let (mut control, server) = control_pair().await;
    let relay = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let address = relay.local_addr().unwrap();
    let endpoint =
        ClientEndpoint::new(server.peer_addr().unwrap(), "0.0.0.0:0".parse().unwrap()).unwrap();
    let mut tasks = JoinSet::new();
    tasks.spawn(run(server, relay, endpoint));
    control.shutdown().await.unwrap();
    timeout(Duration::from_secs(1), tasks.join_next())
        .await
        .unwrap()
        .unwrap()
        .unwrap()
        .unwrap();
    let released = UdpSocket::bind(address).await.unwrap();
    assert_eq!(released.local_addr().unwrap(), address);
}

#[tokio::test]
async fn pins_first_valid_source_and_rejects_later_spoofs() {
    let (mut control, server) = control_pair().await;
    let relay = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let address = relay.local_addr().unwrap();
    let endpoint =
        ClientEndpoint::new(server.peer_addr().unwrap(), "0.0.0.0:0".parse().unwrap()).unwrap();
    let mut tasks = JoinSet::new();
    tasks.spawn(run(server, relay, endpoint));
    let echo = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let echo_addr = echo.local_addr().unwrap();
    let header = new_udp_header(echo_addr).unwrap();
    let client = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let malformed = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    malformed.send_to(&[0, 0, 0], address).await.unwrap();
    let mut packet = header.clone();
    packet.extend_from_slice(b"valid");
    client.send_to(&packet, address).await.unwrap();
    let spoof = UdpSocket::bind("127.0.0.2:0").await.unwrap();
    let mut packet = header.clone();
    packet.extend_from_slice(b"spoof");
    spoof.send_to(&packet, address).await.unwrap();
    packet[2] = 1;
    malformed.send_to(&packet, address).await.unwrap();
    let mut payload = [0; 128];
    let (length, upstream) = timeout(Duration::from_secs(1), echo.recv_from(&mut payload))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&payload[..length], b"valid");
    assert_ne!(upstream, address);
    spoof.send_to(b"uncontacted", upstream).await.unwrap();
    echo.send_to(b"reply", upstream).await.unwrap();
    let (length, origin) = timeout(Duration::from_secs(1), client.recv_from(&mut payload))
        .await
        .unwrap()
        .unwrap();
    let (fragment, source, reply) = parse_udp_request(&payload[..length]).await.unwrap();
    assert_eq!(origin, address);
    assert_eq!(fragment, 0);
    assert_eq!(
        source,
        fast_socks5::util::target_addr::TargetAddr::Ip(echo_addr)
    );
    assert_eq!(reply, b"reply");
    control.shutdown().await.unwrap();
    timeout(Duration::from_secs(1), tasks.join_next())
        .await
        .unwrap()
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(UdpSocket::bind(address).await.is_ok());
    assert!(UdpSocket::bind(upstream).await.is_ok());
}

#[tokio::test(start_paused = true)]
async fn admits_first_packet_when_expired_targets_are_finished_but_unreaped() {
    let _clock = crate::udp_target_tests::hold_clock().await;
    let relay = std::sync::Arc::new(UdpSocket::bind("127.0.0.1:0").await.unwrap());
    let address = relay.local_addr().unwrap();
    let client = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let mut endpoint =
        ClientEndpoint::new(client.local_addr().unwrap(), "0.0.0.0:0".parse().unwrap()).unwrap();
    let mut tasks = JoinSet::new();
    let mut destinations = Vec::new();
    {
        let process = packets(&relay, &mut endpoint, &mut tasks);
        tokio::pin!(process);
        for _ in 0..256 {
            let target = UdpSocket::bind("127.0.0.1:0").await.unwrap();
            let mut packet = new_udp_header(target.local_addr().unwrap()).unwrap();
            packet.extend_from_slice(b"initial");
            client.send_to(&packet, address).await.unwrap();
            let mut buffer = [0; 128];
            let (length, upstream) = tokio::select! {
                result = &mut process => panic!("Packet loop ended: {result:?}"),
                received = timeout(Duration::from_secs(1), target.recv_from(&mut buffer)) => {
                    received.unwrap().unwrap()
                }
            };
            assert_eq!(&buffer[..length], b"initial");
            destinations.push((target, upstream));
        }
        tokio::time::advance(Duration::from_secs(61)).await;
        for (_, upstream) in &destinations {
            let deadline = std::time::Instant::now() + Duration::from_secs(1);
            loop {
                match std::net::UdpSocket::bind(upstream) {
                    Ok(lease) => {
                        drop(lease);
                        break;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::AddrInUse => {
                        assert!(
                            std::time::Instant::now() < deadline,
                            "Idle socket not released"
                        );
                        tokio::task::yield_now().await;
                    }
                    Err(error) => panic!("Socket barrier failed: {error}"),
                }
            }
        }
        for target in [
            &destinations[0].0,
            &UdpSocket::bind("127.0.0.1:0").await.unwrap(),
        ] {
            let mut packet = new_udp_header(target.local_addr().unwrap()).unwrap();
            packet.extend_from_slice(b"first-after-expiry");
            client.send_to(&packet, address).await.unwrap();
            let mut buffer = [0; 128];
            tokio::select! {
                result = &mut process => panic!("Packet loop ended: {result:?}"),
                received = timeout(Duration::from_secs(1), target.recv_from(&mut buffer)) => {
                    let (length, _) = received.unwrap().unwrap();
                    assert_eq!(&buffer[..length], b"first-after-expiry");
                }
            }
        }
    }
    tasks.shutdown().await;
}
