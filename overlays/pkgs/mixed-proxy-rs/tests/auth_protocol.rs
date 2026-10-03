use crate::{auth::Authenticator, auth_support::BlockingBackend, support::Proxy};
use std::time::Duration;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::mpsc,
    time::timeout,
};

#[tokio::test]
async fn rejects_fifth_authentication_when_https_and_socks_share_four_workers() {
    let (backend, mut started) = BlockingBackend::new();
    let (_records, receiver) = mpsc::channel(1);
    let proxy = Proxy::with_auth(Authenticator::with_backend(backend), receiver).await;
    let mut calls = Vec::new();
    let mut socks = Vec::new();
    let mut https = Vec::new();
    for _ in 0..2 {
        let mut stream = TcpStream::connect(proxy.address).await.unwrap();
        stream
            .write_all(b"\x05\x01\x02\x01\x04chen\x04test")
            .await
            .unwrap();
        calls.push(started.recv().await.unwrap());
        socks.push(stream);
        let mut stream = proxy.tls().await;
        stream.write_all(b"GET http://127.0.0.1:1/ HTTP/1.1\r\nHost: target\r\nProxy-Authorization: Basic Y2hlbjp0ZXN0\r\n\r\n").await.unwrap();
        calls.push(started.recv().await.unwrap());
        https.push(stream);
    }
    let mut fifth = TcpStream::connect(proxy.address).await.unwrap();
    fifth
        .write_all(b"\x05\x01\x02\x01\x04chen\x04test")
        .await
        .unwrap();
    let extra_call = started.try_recv();
    assert!(
        extra_call.is_err(),
        "fifth call should queue, not start a worker"
    );
    for call in calls {
        call.release().await;
    }
    let fifth_call = timeout(Duration::from_secs(2), started.recv())
        .await
        .expect("timed out waiting for fifth worker")
        .expect("channel closed before fifth worker started");
    fifth_call.release().await;
    let mut accepted = [0; 4];
    timeout(Duration::from_secs(2), fifth.read_exact(&mut accepted))
        .await
        .unwrap()
        .unwrap();
    proxy.stop().await;
    drop((socks, https));
    assert_eq!(accepted, [5, 2, 1, 0]);
    assert!(extra_call.is_err());
}
