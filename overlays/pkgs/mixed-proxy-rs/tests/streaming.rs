use crate::{auth_support::Reply, support::Proxy};
use std::time::Duration;
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    sync::oneshot,
    task::JoinSet,
    time::timeout,
};

async fn header(stream: &mut (impl AsyncRead + Unpin)) -> Vec<u8> {
    let mut result = Vec::new();
    let mut byte = [0];
    while !result.ends_with(b"\r\n\r\n") {
        stream.read_exact(&mut byte).await.unwrap();
        result.extend_from_slice(&byte);
    }
    result
}

#[tokio::test]
async fn streams_both_bodies_when_final_chunks_are_withheld() {
    let proxy = Proxy::start(Reply::Allow).await;
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = target.local_addr().unwrap();
    let (upload_seen, upload) = oneshot::channel();
    let (release_response, response_released) = oneshot::channel();
    let mut tasks = JoinSet::new();
    tasks.spawn(async move {
        let (mut stream, _) = target.accept().await.unwrap();
        let headers = header(&mut stream).await;
        assert!(headers.starts_with(b"POST /upload HTTP/1.1"));
        let mut body = [0; 9];
        stream.read_exact(&mut body).await.unwrap();
        assert_eq!(&body, b"4\r\npart\r\n");
        upload_seen.send(()).unwrap();
        let mut end = [0; 5];
        stream.read_exact(&mut end).await.unwrap();
        assert_eq!(&end, b"0\r\n\r\n");
        stream.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nfirst\r\n").await.unwrap();
        response_released.await.unwrap();
        stream.write_all(b"4\r\nlast\r\n0\r\n\r\n").await.unwrap();
    });
    let mut stream = proxy.tls().await;
    stream.write_all(format!("POST http://{address}/upload HTTP/1.1\r\nHost: {address}\r\nProxy-Authorization: Basic Y2hlbjp0ZXN0\r\nTransfer-Encoding: chunked\r\n\r\n4\r\npart\r\n").as_bytes()).await.unwrap();
    timeout(Duration::from_secs(1), upload)
        .await
        .unwrap()
        .unwrap();
    stream.write_all(b"0\r\n\r\n").await.unwrap();
    let headers = timeout(Duration::from_secs(1), header(&mut stream))
        .await
        .unwrap();
    assert!(headers.starts_with(b"HTTP/1.1 200"));
    let mut first = [0; 10];
    timeout(Duration::from_secs(1), stream.read_exact(&mut first))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&first, b"5\r\nfirst\r\n");
    release_response.send(()).unwrap();
    let mut last = [0; 14];
    timeout(Duration::from_secs(1), stream.read_exact(&mut last))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&last, b"4\r\nlast\r\n0\r\n\r\n");
    tasks.join_next().await.unwrap().unwrap();
    proxy.stop().await;
}
