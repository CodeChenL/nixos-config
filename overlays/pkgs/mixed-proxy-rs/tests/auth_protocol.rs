use crate::{
    auth::{Authenticator, WORKERS},
    auth_support::BlockingBackend,
    support::Proxy,
};
use std::time::Duration;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::mpsc,
    time::timeout,
};

#[tokio::test]
async fn queues_authentication_when_https_and_socks_share_sixteen_workers() {
    let (backend, mut started) = BlockingBackend::new();
    let (_records, receiver) = mpsc::channel(1);
    let proxy = Proxy::with_auth(Authenticator::with_backend(backend), receiver).await;
    let mut calls = Vec::new();
    let mut socks = Vec::new();
    let mut https = Vec::new();
    for _ in 0..WORKERS / 2 {
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
    let mut queued = TcpStream::connect(proxy.address).await.unwrap();
    queued
        .write_all(b"\x05\x01\x02\x01\x04chen\x04test")
        .await
        .unwrap();
    let mut method = [0; 2];
    queued.read_exact(&mut method).await.unwrap();
    assert_eq!(method, [5, 2]);
    assert!(
        timeout(Duration::from_millis(100), queued.read_u8())
            .await
            .is_err()
    );
    let extra_call = started.try_recv();
    assert!(
        extra_call.is_err(),
        "queued authentication must not start an extra worker"
    );
    for call in calls {
        call.release().await;
    }
    let queued_call = timeout(Duration::from_secs(2), started.recv())
        .await
        .expect("timed out waiting for queued worker")
        .expect("channel closed before queued worker started");
    queued_call.release().await;
    let mut accepted = [0; 2];
    timeout(Duration::from_secs(2), queued.read_exact(&mut accepted))
        .await
        .unwrap()
        .unwrap();
    proxy.stop().await;
    drop((socks, https));
    assert_eq!(accepted, [1, 0]);
    assert!(extra_call.is_err());
}
