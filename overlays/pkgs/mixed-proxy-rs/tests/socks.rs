use crate::{auth_support::Reply, support::Proxy};
use std::{net::SocketAddr, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream, UdpSocket},
    task::JoinSet,
    time::timeout,
};

async fn authenticated(proxy: &Proxy) -> TcpStream {
    let mut stream = TcpStream::connect(proxy.address).await.unwrap();
    stream.write_all(&[5]).await.unwrap();
    stream.write_all(&[2, 0, 2]).await.unwrap();
    let mut method = [0; 2];
    timeout(Duration::from_secs(1), stream.read_exact(&mut method))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(method, [5, 2]);
    stream.write_all(b"\x01\x04chen\x04test").await.unwrap();
    stream.read_exact(&mut method).await.unwrap();
    assert_eq!(method, [1, 0]);
    stream
}

async fn associate(proxy: &Proxy) -> (TcpStream, SocketAddr) {
    let mut stream = authenticated(proxy).await;
    stream
        .write_all(&[5, 3, 0, 1, 0, 0, 0, 0, 0, 0])
        .await
        .unwrap();
    let mut reply = [0; 10];
    stream.read_exact(&mut reply).await.unwrap();
    assert_eq!(&reply[..8], &[5, 0, 0, 1, 47, 254, 74, 103]);
    let port = u16::from_be_bytes([reply[8], reply[9]]);
    assert!((20000..=20127).contains(&port));
    (stream, SocketAddr::new(proxy.address.ip(), port))
}

#[tokio::test]
async fn isolates_associations_when_public_ip_differs_from_bind_ip() {
    let mut proxy = Proxy::start(Reply::Allow).await;
    let (first, first_address) = associate(&proxy).await;
    let (second, second_address) = associate(&proxy).await;
    assert_ne!(first_address, second_address);
    assert!(UdpSocket::bind(first_address).await.is_err());
    assert!(UdpSocket::bind(second_address).await.is_err());
    let record = proxy.auth_records.recv().await.unwrap();
    assert_eq!(record.username, "chen");
    assert_eq!(record.password, "test");
    proxy.stop().await;
    assert!(UdpSocket::bind(first_address).await.is_ok());
    assert!(UdpSocket::bind(second_address).await.is_ok());
    drop((first, second));
}

#[tokio::test]
async fn denies_bind_when_authenticated() {
    let proxy = Proxy::start(Reply::Allow).await;
    let mut stream = authenticated(&proxy).await;
    stream
        .write_all(&[5, 2, 0, 1, 127, 0, 0, 1, 0, 80])
        .await
        .unwrap();
    let mut reply = [0; 10];
    stream.read_exact(&mut reply).await.unwrap();
    assert_eq!(reply[1], 2);
    proxy.stop().await;
}

#[tokio::test]
async fn denies_authentication_when_backend_or_pam_stages_fail() {
    for reply in [
        Reply::Deny,
        Reply::Unavailable,
        Reply::AuthenticationFailed,
        Reply::AccountExpired,
        Reply::PasswordChangeRequired,
    ] {
        let proxy = Proxy::start(reply).await;
        let mut stream = TcpStream::connect(proxy.address).await.unwrap();
        stream
            .write_all(b"\x05\x01\x02\x01\x04chen\x04test")
            .await
            .unwrap();
        let mut reply = [0; 4];
        stream.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply, [5, 2, 1, 255]);
        proxy.stop().await;
    }
}

#[tokio::test]
async fn relays_after_half_close_when_socks_connect_uses_domain() {
    let proxy = Proxy::start(Reply::Allow).await;
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut tasks = JoinSet::new();
    let port = target.local_addr().unwrap().port();
    tasks.spawn(async move {
        let (mut stream, _) = target.accept().await.unwrap();
        let mut bytes = Vec::new();
        stream.read_to_end(&mut bytes).await.unwrap();
        assert_eq!(bytes, b"hello");
        stream.write_all(b"after-eof").await.unwrap();
    });
    let mut stream = authenticated(&proxy).await;
    let mut request = b"\x05\x01\x00\x03\x09localhost".to_vec();
    request.extend_from_slice(&port.to_be_bytes());
    stream.write_all(&request).await.unwrap();
    let mut reply = [0; 10];
    stream.read_exact(&mut reply).await.unwrap();
    assert_eq!(reply[1], 0);
    stream.write_all(b"hello").await.unwrap();
    stream.shutdown().await.unwrap();
    let mut bytes = Vec::new();
    timeout(Duration::from_secs(1), stream.read_to_end(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(bytes, b"after-eof");
    tasks.join_next().await.unwrap().unwrap();
    proxy.stop().await;
}
