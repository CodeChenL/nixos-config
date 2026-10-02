use crate::{auth_support::Reply, support::Proxy};
use bytes::Bytes;
use http_body_util::BodyExt;
use hyper::{
    HeaderMap, Request, Response,
    body::{Body, Frame, Incoming},
    service::service_fn,
};
use hyper_util::rt::TokioIo;
use std::{
    collections::VecDeque,
    pin::Pin,
    task::{Context, Poll},
    time::Duration,
};
use tokio::{net::TcpListener, task::JoinSet, time::timeout};

struct WithTrailers(VecDeque<Frame<Bytes>>);
impl Body for WithTrailers {
    type Data = Bytes;
    type Error = std::convert::Infallible;
    fn poll_frame(
        mut self: Pin<&mut Self>,
        _context: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Self::Error>>> {
        Poll::Ready(self.0.pop_front().map(Ok))
    }
}

fn payload() -> WithTrailers {
    let mut trailers = HeaderMap::new();
    trailers.insert("proxy-authorization", "Basic Y2hlbjp0ZXN0".parse().unwrap());
    trailers.insert("connection", "x-hop".parse().unwrap());
    trailers.insert("x-hop", "private".parse().unwrap());
    trailers.insert("x-business", "kept".parse().unwrap());
    WithTrailers(VecDeque::from([
        Frame::data(Bytes::from_static(b"payload")),
        Frame::trailers(trailers),
    ]))
}

#[tokio::test]
async fn strips_hop_headers_when_streamed_bodies_include_trailers() {
    let proxy = Proxy::start(Reply::Allow).await;
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = target.local_addr().unwrap();
    let mut tasks = JoinSet::new();
    tasks.spawn(async move {
        let (stream, _) = target.accept().await.unwrap();
        let service = service_fn(|request: Request<Incoming>| async move {
            let collected = request.into_body().collect().await.unwrap();
            assert!(collected.trailers().is_none());
            assert_eq!(collected.to_bytes(), "payload");
            let mut response = Response::new(payload());
            response
                .headers_mut()
                .insert("connection", "close".parse().unwrap());
            response.headers_mut().insert(
                "trailer",
                "proxy-authorization, connection, x-hop, x-business"
                    .parse()
                    .unwrap(),
            );
            Ok::<_, std::convert::Infallible>(response)
        });
        hyper::server::conn::http1::Builder::new()
            .serve_connection(TokioIo::new(stream), service)
            .await
            .unwrap();
    });
    let (mut sender, connection) =
        hyper::client::conn::http1::handshake(TokioIo::new(proxy.tls().await))
            .await
            .unwrap();
    tasks.spawn(async move {
        connection.await.unwrap();
    });
    let request = Request::post(format!("http://{address}/trailers"))
        .header("proxy-authorization", "Basic Y2hlbjp0ZXN0")
        .header(
            "trailer",
            "proxy-authorization, connection, x-hop, x-business",
        )
        .header("te", "trailers")
        .body(payload())
        .unwrap();
    let response = timeout(Duration::from_secs(1), sender.send_request(request))
        .await
        .unwrap()
        .unwrap();
    let collected = response.into_body().collect().await.unwrap();
    assert!(collected.trailers().is_none());
    assert_eq!(collected.to_bytes(), "payload");
    drop(sender);
    tasks.shutdown().await;
    proxy.stop().await;
}
