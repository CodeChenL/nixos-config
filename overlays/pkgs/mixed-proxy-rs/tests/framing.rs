use crate::{auth_support::Reply, support::Proxy};
use bytes::Bytes;
use http_body_util::{BodyExt, Empty, Full};
use hyper::{Request, Response, body::Incoming, service::service_fn};
use hyper_util::rt::TokioIo;
use std::time::Duration;
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    sync::mpsc,
    task::JoinSet,
    time::timeout,
};

const GZIP: &[u8] =
    b"\x1f\x8b\x08\0\0\0\0\0\0\x03\xcb\x48\xcd\xc9\xc9\x07\0\x86\xa6\x10\x36\x05\0\0\0";

async fn header(stream: &mut (impl AsyncRead + Unpin)) -> Vec<u8> {
    let mut bytes = Vec::new();
    let mut byte = [0];
    while !bytes.ends_with(b"\r\n\r\n") {
        stream.read_exact(&mut byte).await.unwrap();
        bytes.extend_from_slice(&byte);
    }
    bytes
}

async fn chunked_method(method: &str) {
    let proxy = Proxy::start(Reply::Allow).await;
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = target.local_addr().unwrap();
    let (received, mut bodies) = mpsc::channel(1);
    let mut tasks = JoinSet::new();
    tasks.spawn(async move {
        let (stream, _) = target.accept().await.unwrap();
        let service = service_fn(move |request: Request<Incoming>| {
            let received = received.clone();
            async move {
                let bytes = request.into_body().collect().await.unwrap().to_bytes();
                received.send(bytes).await.unwrap();
                Ok::<_, std::convert::Infallible>(Response::new(Empty::<Bytes>::new()))
            }
        });
        hyper::server::conn::http1::Builder::new()
            .serve_connection(TokioIo::new(stream), service)
            .await
            .unwrap();
    });
    let mut stream = proxy.tls().await;
    stream.write_all(format!("{method} http://{address}/body HTTP/1.1\r\nHost: {address}\r\nProxy-Authorization: Basic Y2hlbjp0ZXN0\r\ntRaNsFeR-EnCoDiNg: \tChUnKeD \t\r\n\r\n4\r\npart\r\n4\r\nlast\r\n0\r\n\r\n").as_bytes()).await.unwrap();
    let bytes = timeout(Duration::from_secs(1), bodies.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(bytes, "partlast");
    tasks.join_next().await.unwrap().unwrap();
    proxy.stop().await;
}

#[tokio::test]
async fn forwards_full_body_when_get_is_chunked() {
    chunked_method("GET").await;
}

#[tokio::test]
async fn forwards_full_body_when_head_is_chunked() {
    chunked_method("HEAD").await;
}

async fn rejected_request(encoding: &str) {
    let mut proxy = Proxy::start(Reply::Allow).await;
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = target.local_addr().unwrap();
    let mut stream = proxy.tls().await;
    let request = format!(
        "POST http://{address}/body HTTP/1.1\r\nHost: {address}\r\nProxy-Authorization: Basic Y2hlbjp0ZXN0\r\n{encoding}\r\n\r\n{:x}\r\n",
        GZIP.len()
    );
    stream.write_all(request.as_bytes()).await.unwrap();
    stream.write_all(GZIP).await.unwrap();
    stream.write_all(b"\r\n0\r\n\r\n").await.unwrap();
    let response = timeout(Duration::from_secs(1), async {
        tokio::select! {
            response = header(&mut stream) => response,
            accepted = target.accept() => panic!("unsupported coding reached target: {}", accepted.unwrap().1),
        }
    }).await.unwrap();
    assert!(response.starts_with(b"HTTP/1.1 501"));
    assert_eq!(proxy.auth_records.recv().await.unwrap().username, "chen");
    proxy.stop().await;
}

#[tokio::test]
async fn returns_501_without_dial_when_request_transfer_coding_is_gzip() {
    rejected_request("Transfer-Encoding: gzip, chunked").await;
}

#[tokio::test]
async fn returns_501_when_request_transfer_coding_spans_duplicate_headers() {
    rejected_request("Transfer-Encoding: GZip\r\ntransfer-encoding: CHUNKED").await;
}

async fn rejected_response(encoding: &str) {
    let proxy = Proxy::start(Reply::Allow).await;
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = target.local_addr().unwrap();
    let response = format!(
        "HTTP/1.1 200 OK\r\n{encoding}\r\nConnection: close\r\n\r\n{:x}\r\n",
        GZIP.len()
    );
    let mut tasks = JoinSet::new();
    tasks.spawn(async move {
        let (mut stream, _) = target.accept().await.unwrap();
        header(&mut stream).await;
        stream.write_all(response.as_bytes()).await.unwrap();
        stream.write_all(GZIP).await.unwrap();
        stream.write_all(b"\r\n0\r\n\r\n").await.unwrap();
    });
    let mut stream = proxy.tls().await;
    stream.write_all(format!("GET http://{address}/body HTTP/1.1\r\nHost: {address}\r\nProxy-Authorization: Basic Y2hlbjp0ZXN0\r\n\r\n").as_bytes()).await.unwrap();
    let response = timeout(Duration::from_secs(1), header(&mut stream))
        .await
        .unwrap();
    assert!(response.starts_with(b"HTTP/1.1 502"));
    tasks.join_next().await.unwrap().unwrap();
    proxy.stop().await;
}

#[tokio::test]
async fn returns_502_when_upstream_transfer_coding_is_gzip() {
    rejected_response("Transfer-Encoding: gzip, chunked").await;
}

#[tokio::test]
async fn returns_502_when_upstream_transfer_coding_spans_duplicate_headers() {
    rejected_response("Transfer-Encoding: GZip\r\ntransfer-encoding: CHUNKED").await;
}

#[tokio::test]
async fn preserves_encoded_bytes_when_gzip_is_content_encoding() {
    let proxy = Proxy::start(Reply::Allow).await;
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = target.local_addr().unwrap();
    let (received, mut bodies) = mpsc::channel(1);
    let mut tasks = JoinSet::new();
    tasks.spawn(async move {
        let (stream, _) = target.accept().await.unwrap();
        let service = service_fn(move |request: Request<Incoming>| {
            let received = received.clone();
            async move {
                assert_eq!(request.headers()["content-encoding"], "gzip");
                let bytes = request.into_body().collect().await.unwrap().to_bytes();
                received.send(bytes).await.unwrap();
                let mut response = Response::new(Full::new(Bytes::from_static(GZIP)));
                response
                    .headers_mut()
                    .insert("content-encoding", "gzip".parse().unwrap());
                Ok::<_, std::convert::Infallible>(response)
            }
        });
        hyper::server::conn::http1::Builder::new()
            .serve_connection(TokioIo::new(stream), service)
            .await
            .unwrap();
    });
    let mut stream = proxy.tls().await;
    stream.write_all(format!("POST http://{address}/body HTTP/1.1\r\nHost: {address}\r\nProxy-Authorization: Basic Y2hlbjp0ZXN0\r\nContent-Encoding: gzip\r\nContent-Length: {}\r\n\r\n", GZIP.len()).as_bytes()).await.unwrap();
    stream.write_all(GZIP).await.unwrap();
    let response = timeout(Duration::from_secs(1), header(&mut stream))
        .await
        .unwrap();
    assert!(response.starts_with(b"HTTP/1.1 200"));
    assert!(
        String::from_utf8(response)
            .unwrap()
            .to_ascii_lowercase()
            .contains("content-encoding: gzip\r\n")
    );
    let mut bytes = vec![0; GZIP.len()];
    stream.read_exact(&mut bytes).await.unwrap();
    assert_eq!(bytes, GZIP);
    assert_eq!(bodies.recv().await.unwrap(), GZIP);
    tasks.join_next().await.unwrap().unwrap();
    proxy.stop().await;
}
