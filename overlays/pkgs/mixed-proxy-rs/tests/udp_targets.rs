use crate::relay::{ClientEndpoint, run};
use fast_socks5::{new_udp_header, parse_udp_request, util::target_addr::TargetAddr};
use std::{net::SocketAddr, time::Duration};
use tokio::{
    io::AsyncWriteExt,
    net::{TcpListener, TcpStream, UdpSocket},
    task::JoinSet,
    time::{advance, timeout},
};

struct Association {
    control: TcpStream,
    client: UdpSocket,
    address: SocketAddr,
    tasks: JoinSet<anyhow::Result<()>>,
    _clock: std::sync::mpsc::Sender<()>,
}

pub async fn hold_clock() -> std::sync::mpsc::Sender<()> {
    let (clock, stopped) = std::sync::mpsc::channel();
    let (started, ready) = tokio::sync::oneshot::channel();
    let _watchdog = tokio::task::spawn_blocking(move || {
        started.send(()).unwrap();
        match stopped.recv_timeout(Duration::from_secs(5)) {
            Ok(()) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => (),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                panic!("UDP socket barrier stalled")
            }
        }
    });
    ready.await.unwrap();
    clock
}

impl Association {
    async fn new() -> Self {
        let clock = hold_clock().await;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let control = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (server, peer) = listener.accept().await.unwrap();
        let relay = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let address = relay.local_addr().unwrap();
        let client = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let endpoint = ClientEndpoint::new(peer, "0.0.0.0:0".parse().unwrap()).unwrap();
        let mut tasks = JoinSet::new();
        tasks.spawn(run(server, relay, endpoint));
        Self {
            control,
            client,
            address,
            tasks,
            _clock: clock,
        }
    }

    async fn send(&self, target: &UdpSocket, payload: &[u8]) -> SocketAddr {
        let mut packet = new_udp_header(target.local_addr().unwrap()).unwrap();
        packet.extend_from_slice(payload);
        self.client.send_to(&packet, self.address).await.unwrap();
        let mut buffer = [0; 128];
        let (length, upstream) = timeout(Duration::from_secs(1), target.recv_from(&mut buffer))
            .await
            .unwrap_or_else(|error| panic!("UDP payload {payload:?} not forwarded: {error}"))
            .unwrap();
        assert_eq!(&buffer[..length], payload);
        upstream
    }

    async fn inbound(&self, target: &UdpSocket, upstream: SocketAddr) {
        target.send_to(b"inbound", upstream).await.unwrap();
        let mut buffer = [0; 128];
        let (length, frontend) =
            timeout(Duration::from_secs(1), self.client.recv_from(&mut buffer))
                .await
                .unwrap()
                .unwrap();
        let (fragment, origin, payload) = parse_udp_request(&buffer[..length]).await.unwrap();
        assert_eq!(frontend, self.address);
        assert_eq!(fragment, 0);
        assert_eq!(origin, TargetAddr::Ip(target.local_addr().unwrap()));
        assert_eq!(payload, b"inbound");
    }

    async fn close(mut self) {
        self.control.shutdown().await.unwrap();
        timeout(Duration::from_secs(1), self.tasks.join_next())
            .await
            .unwrap()
            .unwrap()
            .unwrap()
            .unwrap();
        assert!(UdpSocket::bind(self.address).await.is_ok());
    }
}

#[tokio::test(start_paused = true)]
async fn admits_target_257_when_idle_targets_expire_on_the_same_association() {
    let association = Association::new().await;
    let mut destinations = Vec::new();
    for _ in 0..256 {
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let upstream = association.send(&socket, b"initial").await;
        association.inbound(&socket, upstream).await;
        destinations.push((socket, upstream));
    }
    let extra = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let mut overflow = new_udp_header(extra.local_addr().unwrap()).unwrap();
    overflow.extend_from_slice(b"rejected");
    association
        .client
        .send_to(&overflow, association.address)
        .await
        .unwrap();
    let (active, upstream) = &destinations[0];
    assert_eq!(association.send(active, b"barrier").await, *upstream);
    assert_eq!(
        extra.try_recv(&mut [0; 128]).unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    advance(Duration::from_secs(30)).await;
    association.inbound(active, *upstream).await;

    advance(Duration::from_secs(31)).await;

    association.inbound(active, *upstream).await;
    let admitted = association.send(&extra, b"first-after-expiry").await;
    association.inbound(&extra, admitted).await;
    let (expired, old_upstream) = &destinations[1];
    let _lease = std::net::UdpSocket::bind(old_upstream).unwrap();
    let recreated = association.send(expired, b"recreated").await;
    assert_ne!(recreated, *old_upstream);
    association.close().await;
    for address in [*upstream, admitted, recreated] {
        assert!(std::net::UdpSocket::bind(address).is_ok());
    }
}

#[tokio::test(start_paused = true)]
async fn retains_upstream_socket_when_only_outbound_traffic_resets_idle_deadline() {
    let association = Association::new().await;
    let target = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let upstream = association.send(&target, b"initial").await;
    advance(Duration::from_secs(30)).await;
    assert_eq!(association.send(&target, b"outbound-only").await, upstream);

    advance(Duration::from_secs(31)).await;

    assert_eq!(association.send(&target, b"still-active").await, upstream);
    association.close().await;
    assert!(std::net::UdpSocket::bind(upstream).is_ok());
}

#[tokio::test(start_paused = true)]
async fn recreates_expired_target_when_first_datagram_arrives_after_sixty_seconds() {
    let association = Association::new().await;
    let target = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let upstream = association.send(&target, b"initial").await;
    advance(Duration::from_secs(59)).await;
    let barrier = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    association.send(&barrier, b"before-deadline").await;
    assert_eq!(
        std::net::UdpSocket::bind(upstream).unwrap_err().kind(),
        std::io::ErrorKind::AddrInUse
    );

    advance(Duration::from_secs(2)).await;

    association.send(&barrier, b"after-deadline").await;
    let _lease = std::net::UdpSocket::bind(upstream).unwrap();
    let recreated = association.send(&target, b"first-after-expiry").await;
    assert_ne!(recreated, upstream);
    association.inbound(&target, recreated).await;
    association.close().await;
}

#[tokio::test]
async fn returns_origin_address_when_targets_use_domain_or_ipv6_encoding() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut control = TcpStream::connect(listener.local_addr().unwrap())
        .await
        .unwrap();
    let (server, peer) = listener.accept().await.unwrap();
    let relay = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let relay_addr = relay.local_addr().unwrap();
    let client = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let endpoint = ClientEndpoint::new(peer, "0.0.0.0:0".parse().unwrap()).unwrap();
    let mut tasks = JoinSet::new();
    tasks.spawn(run(server, relay, endpoint));
    for bind in ["127.0.0.1:0", "[::1]:0"] {
        let echo = UdpSocket::bind(bind).await.unwrap();
        let origin = echo.local_addr().unwrap();
        let target = match origin {
            SocketAddr::V4(_) => TargetAddr::Domain("127.0.0.1".to_owned(), origin.port()),
            SocketAddr::V6(_) => TargetAddr::Ip(origin),
        };
        let mut packet = new_udp_header(target).unwrap();
        packet.extend_from_slice(b"hello");
        client.send_to(&packet, relay_addr).await.unwrap();
        let mut buffer = [0; 128];
        let (length, upstream) = timeout(Duration::from_secs(1), echo.recv_from(&mut buffer))
            .await
            .unwrap()
            .unwrap();
        echo.send_to(&buffer[..length], upstream).await.unwrap();
        let (length, frontend) = timeout(Duration::from_secs(1), client.recv_from(&mut buffer))
            .await
            .unwrap()
            .unwrap();
        let (fragment, target, bytes) = parse_udp_request(&buffer[..length]).await.unwrap();
        assert_eq!(frontend, relay_addr);
        assert_eq!(fragment, 0);
        assert_eq!(target, TargetAddr::Ip(origin));
        assert_eq!(bytes, b"hello");
    }
    control.shutdown().await.unwrap();
    tasks.join_next().await.unwrap().unwrap().unwrap();
}
