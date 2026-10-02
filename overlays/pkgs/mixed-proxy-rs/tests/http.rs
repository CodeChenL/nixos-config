use crate::{auth_support::Reply, support::Proxy};
use bytes::Bytes;
use http_body_util::{BodyExt, Empty};
use hyper::{Request, StatusCode};
use hyper_util::rt::TokioIo;
use std::time::Duration;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    task::JoinSet,
    time::timeout,
};

#[tokio::test]
async fn reauthenticates_each_request_when_tls_connection_is_reused() {
    let mut proxy = Proxy::start(Reply::Allow).await;
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = target.local_addr().unwrap();
    let mut tasks = JoinSet::new();
    tasks.spawn(async move {
        let (mut stream, _) = target.accept().await.unwrap();
        let mut bytes = Vec::new();
        let mut byte = [0];
        while !bytes.ends_with(b"\r\n\r\n") { stream.read_exact(&mut byte).await.unwrap(); bytes.extend_from_slice(&byte); }
        let request = String::from_utf8(bytes).unwrap().to_ascii_lowercase();
        assert!(request.starts_with("get /stream?x=1 http/1.1"));
        assert!(!request.contains("proxy-authorization") && !request.contains("x-secret") && !request.contains("proxy-connection"));
        stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close, x-hop\r\nx-hop: hidden\r\n\r\nhello").await.unwrap();
    });
    let (mut sender, connection) =
        hyper::client::conn::http1::handshake(TokioIo::new(proxy.tls().await))
            .await
            .unwrap();
    tasks.spawn(async move {
        connection.await.unwrap();
    });
    let request = Request::get(format!("http://{address}/stream?x=1"))
        .header("proxy-authorization", "Basic Y2hlbjp0ZXN0")
        .header("connection", "x-secret")
        .header("x-secret", "hidden")
        .header("proxy-connection", "keep-alive")
        .body(Empty::<Bytes>::new())
        .unwrap();
    let response = timeout(Duration::from_secs(2), sender.send_request(request))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert!(!response.headers().contains_key("x-hop"));
    assert_eq!(
        response.into_body().collect().await.unwrap().to_bytes(),
        "hello"
    );
    let record = proxy.auth_records.recv().await.unwrap();
    assert_eq!(record.username, "chen");
    assert_eq!(record.password, "test");
    let request = Request::get("http://127.0.0.1:1/")
        .header("proxy-authorization", "Basic Y2hlbjp0ZXN0")
        .body(Empty::<Bytes>::new())
        .unwrap();
    let response = sender.send_request(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
    assert_eq!(proxy.auth_records.recv().await.unwrap().password, "test");
    let request = Request::get("http://127.0.0.1:1/")
        .body(Empty::<Bytes>::new())
        .unwrap();
    let response = sender.send_request(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::PROXY_AUTHENTICATION_REQUIRED);
    assert_eq!(
        response.headers()["proxy-authenticate"],
        "Basic realm=\"mixed-proxy\""
    );
    drop(response);
    drop(sender);
    tasks.shutdown().await;
    assert!(proxy.auth_records.try_recv().is_err());
    proxy.stop().await;
}

#[tokio::test]
async fn refuses_target_dial_when_backend_rejects_connect() {
    for reply in [
        Reply::Deny,
        Reply::Unavailable,
        Reply::AuthenticationFailed,
        Reply::AccountExpired,
        Reply::PasswordChangeRequired,
    ] {
        let proxy = Proxy::start(reply).await;
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut stream = proxy.tls().await;
        stream.write_all(format!("CONNECT {} HTTP/1.1\r\nHost: target\r\nProxy-Authorization: Basic Y2hlbjp0ZXN0\r\n\r\n", target.local_addr().unwrap()).as_bytes()).await.unwrap();
        let mut buffer = [0; 512];
        let length = timeout(Duration::from_secs(2), stream.read(&mut buffer))
            .await
            .unwrap()
            .unwrap();
        assert!(buffer[..length].starts_with(b"HTTP/1.1 407"));
        assert!(
            timeout(Duration::from_millis(30), target.accept())
                .await
                .is_err()
        );
        proxy.stop().await;
    }
}

#[tokio::test]
async fn drains_response_when_connect_client_half_closes() {
    let proxy = Proxy::start(Reply::Allow).await;
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = target.local_addr().unwrap();
    let mut tasks = JoinSet::new();
    tasks.spawn(async move {
        let (mut stream, _) = target.accept().await.unwrap();
        let mut request = Vec::new();
        stream.read_to_end(&mut request).await.unwrap();
        assert_eq!(request, b"request");
        stream.write_all(b"after-eof").await.unwrap();
        stream.shutdown().await.unwrap();
    });
    let mut stream = proxy.tls().await;
    stream.write_all(format!("CONNECT {address} HTTP/1.1\r\nHost: {address}\r\nProxy-Authorization: Basic Y2hlbjp0ZXN0\r\n\r\n").as_bytes()).await.unwrap();
    let mut response = Vec::new();
    let mut byte = [0];
    while !response.ends_with(b"\r\n\r\n") {
        stream.read_exact(&mut byte).await.unwrap();
        response.extend_from_slice(&byte);
    }
    assert!(response.starts_with(b"HTTP/1.1 200"));
    stream.write_all(b"request").await.unwrap();
    stream.shutdown().await.unwrap();
    let mut bytes = Vec::new();
    timeout(Duration::from_secs(2), stream.read_to_end(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(bytes, b"after-eof");
    tasks.join_next().await.unwrap().unwrap();
    proxy.stop().await;
}
