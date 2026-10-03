use crate::{auth_support::Reply, support::Proxy};
use fast_socks5::{new_udp_header, parse_udp_request, util::target_addr::TargetAddr};
use std::{net::SocketAddr, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpStream, UdpSocket},
    time::timeout,
};

#[tokio::test]
async fn updates_all_target_reply_ports_when_cross_ip_client_rebinds() {
    let proxy = Proxy::start(Reply::Allow).await;
    let mut control = TcpStream::connect(proxy.address).await.unwrap();
    control
        .write_all(b"\x05\x01\x02\x01\x04chen\x04test")
        .await
        .unwrap();
    let mut auth = [0; 4];
    control.read_exact(&mut auth).await.unwrap();
    assert_eq!(auth, [5, 2, 1, 0]);
    control
        .write_all(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
        .await
        .unwrap();
    let mut response = [0; 10];
    control.read_exact(&mut response).await.unwrap();
    assert_eq!(&response[..4], &[5, 0, 0, 1]);
    let relay = SocketAddr::new(
        proxy.address.ip(),
        u16::from_be_bytes([response[8], response[9]]),
    );
    let old_client = UdpSocket::bind("127.0.0.2:0").await.unwrap();
    let new_client = UdpSocket::bind("127.0.0.2:0").await.unwrap();
    let mut targets = Vec::new();
    let mut buffer = [0; 128];
    for _ in 0..2 {
        let target = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let mut packet = new_udp_header(target.local_addr().unwrap()).unwrap();
        packet.extend_from_slice(b"initial");
        old_client.send_to(&packet, relay).await.unwrap();
        let (_, upstream) = timeout(Duration::from_secs(1), target.recv_from(&mut buffer))
            .await
            .unwrap()
            .unwrap();
        target.send_to(b"initial-reply", upstream).await.unwrap();
        timeout(Duration::from_secs(1), old_client.recv_from(&mut buffer))
            .await
            .unwrap()
            .unwrap();
        targets.push((target, upstream));
    }
    let mut packet = new_udp_header(targets[0].0.local_addr().unwrap()).unwrap();
    packet.extend_from_slice(b"rebind");
    new_client.send_to(&packet, relay).await.unwrap();
    let (length, upstream) = timeout(Duration::from_secs(1), targets[0].0.recv_from(&mut buffer))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&buffer[..length], b"rebind");
    assert_eq!(upstream, targets[0].1);
    for (target, upstream) in &targets {
        target.send_to(b"server-tick", *upstream).await.unwrap();
        let (length, from) = timeout(Duration::from_secs(1), new_client.recv_from(&mut buffer))
            .await
            .unwrap()
            .unwrap();
        let (fragment, origin, payload) = parse_udp_request(&buffer[..length]).await.unwrap();
        assert_eq!(from, relay);
        assert_eq!(fragment, 0);
        assert_eq!(origin, TargetAddr::Ip(target.local_addr().unwrap()));
        assert_eq!(payload, b"server-tick");
    }
    assert!(
        timeout(Duration::from_millis(50), old_client.recv_from(&mut buffer))
            .await
            .is_err()
    );
    control.shutdown().await.unwrap();
    proxy.stop().await;
    assert!(UdpSocket::bind(relay).await.is_ok());
    for (_, upstream) in targets {
        assert!(UdpSocket::bind(upstream).await.is_ok());
    }
}
