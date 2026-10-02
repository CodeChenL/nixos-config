use crate::{
    credentials::Credentials,
    headers,
    server::State,
    transport::{self, SETUP_TIMEOUT},
};
use anyhow::Context;
use bytes::Bytes;
use fast_socks5::util::target_addr::TargetAddr;
use http_body_util::{BodyExt, Empty, combinators::BoxBody};
use hyper::{
    Method, Request, Response, StatusCode, Uri,
    body::{Body as _, Incoming},
    service::service_fn,
};
use hyper_util::rt::{TokioIo, TokioTimer};
use std::{convert::Infallible, future::Future, net::SocketAddr, pin::Pin, sync::Arc};
use tokio::net::TcpStream;
use tokio::{io::copy_bidirectional, sync::mpsc, task::JoinSet, time::timeout};
use tokio_rustls::server::TlsStream;

type Body = BoxBody<Bytes, hyper::Error>;
type Task = Pin<Box<dyn Future<Output = anyhow::Result<()>> + Send>>;

#[derive(Clone)]
struct Session {
    state: Arc<State>,
    peer: SocketAddr,
    tasks: mpsc::Sender<Task>,
}

pub async fn serve(stream: TlsStream<TcpStream>, state: Arc<State>) -> anyhow::Result<()> {
    let peer = stream.get_ref().0.peer_addr()?;
    let (sender, mut receiver) = mpsc::channel::<Task>(16);
    let session = Session {
        state,
        peer,
        tasks: sender,
    };
    let service = service_fn(move |request| {
        let session = session.clone();
        async move { Ok::<_, Infallible>(respond(request, &session).await) }
    });
    let connection = hyper::server::conn::http1::Builder::new()
        .timer(TokioTimer::new())
        .header_read_timeout(SETUP_TIMEOUT)
        .serve_connection(TokioIo::new(stream), service)
        .with_upgrades();
    tokio::pin!(connection);
    let mut tasks = JoinSet::new();
    let outcome = loop {
        tokio::select! {
            result = &mut connection => break result,
            task = receiver.recv() => {
                if let Some(task) = task { tasks.spawn(task); }
            }
            completed = tasks.join_next(), if !tasks.is_empty() => {
                if !matches!(completed, Some(Ok(Ok(())))) {
                    tracing::debug!(%peer, "HTTP upstream connection ended");
                }
            }
        }
    };
    while let Ok(task) = receiver.try_recv() {
        tasks.spawn(task);
    }
    outcome?;
    while let Some(result) = tasks.join_next().await {
        if !matches!(result, Ok(Ok(()))) {
            tracing::debug!(%peer, "HTTP tunnel ended");
        }
    }
    Ok(())
}

async fn respond(mut request: Request<Incoming>, session: &Session) -> Response<Body> {
    let accepted = match Credentials::basic(request.headers()) {
        Ok(credentials) => session.state.auth.check(credentials).await,
        Err(_) => false,
    };
    if !accepted {
        let mut response = empty(StatusCode::PROXY_AUTHENTICATION_REQUIRED);
        response.headers_mut().insert(
            "proxy-authenticate",
            hyper::header::HeaderValue::from_static("Basic realm=\"mixed-proxy\""),
        );
        return response;
    }
    if !headers::supported_transfer_encoding(request.headers()) {
        tracing::debug!(peer = %session.peer, "Unsupported HTTP request transfer coding");
        return empty(StatusCode::NOT_IMPLEMENTED);
    }
    headers::strip(request.headers_mut());
    if !request.body().is_end_stream() && request.body().size_hint().exact().is_none() {
        request.headers_mut().insert(
            "transfer-encoding",
            hyper::header::HeaderValue::from_static("chunked"),
        );
    }
    proxy(request, session).await.unwrap_or_else(|_| {
        tracing::debug!(peer = %session.peer, "HTTP forwarding failed");
        empty(StatusCode::BAD_GATEWAY)
    })
}

async fn proxy(
    mut request: Request<Incoming>,
    session: &Session,
) -> anyhow::Result<Response<Body>> {
    if request.method() == Method::CONNECT {
        let authority = request
            .uri()
            .authority()
            .context("Missing CONNECT authority")?;
        if request.uri().scheme().is_some() || request.uri().path_and_query().is_some() {
            return Ok(empty(StatusCode::BAD_REQUEST));
        }
        let port = authority.port_u16().context("Missing CONNECT port")?;
        let target = target(authority.host(), port);
        let mut outbound = transport::dial(&target).await?;
        let upgrade = hyper::upgrade::on(&mut request);
        session
            .tasks
            .send(Box::pin(async move {
                let upgraded = timeout(SETUP_TIMEOUT, upgrade).await??;
                copy_bidirectional(&mut TokioIo::new(upgraded), &mut outbound).await?;
                Ok(())
            }))
            .await
            .map_err(|_| anyhow::anyhow!("HTTP session closed"))?;
        return Ok(empty(StatusCode::OK));
    }
    let uri = request.uri().clone();
    let scheme = match uri.scheme_str() {
        Some("http") => None,
        Some("https") => Some(&session.state.tls.connector),
        Some(_) | None => return Ok(empty(StatusCode::BAD_REQUEST)),
    };
    let authority = uri.authority().context("Missing forwarding authority")?;
    let port = authority
        .port_u16()
        .unwrap_or_else(|| if scheme.is_some() { 443 } else { 80 });
    let socket = transport::forward(&target(authority.host(), port), scheme).await?;
    *request.uri_mut() = uri
        .path_and_query()
        .map_or_else(|| "/".parse::<Uri>(), |path| path.as_str().parse::<Uri>())?;
    request
        .headers_mut()
        .insert("host", authority.as_str().parse()?);
    request.headers_mut().insert(
        "connection",
        hyper::header::HeaderValue::from_static("close"),
    );
    let (mut sender, connection) = timeout(
        SETUP_TIMEOUT,
        hyper::client::conn::http1::handshake(TokioIo::new(socket)),
    )
    .await??;
    session
        .tasks
        .send(Box::pin(async move {
            connection.await?;
            Ok(())
        }))
        .await
        .map_err(|_| anyhow::anyhow!("HTTP session closed"))?;
    let mut response = sender.send_request(request).await?;
    if !headers::supported_transfer_encoding(response.headers()) {
        tracing::debug!(peer = %session.peer, "Unsupported HTTP upstream transfer coding");
        return Ok(empty(StatusCode::BAD_GATEWAY));
    }
    headers::strip(response.headers_mut());
    Ok(response.map(BodyExt::boxed))
}

fn target(host: &str, port: u16) -> TargetAddr {
    let host = host.trim_matches(['[', ']']);
    host.parse().map_or_else(
        |_| TargetAddr::Domain(host.to_owned(), port),
        |ip| TargetAddr::Ip(SocketAddr::new(ip, port)),
    )
}

fn empty(status: StatusCode) -> Response<Body> {
    let mut response = Response::new(Empty::new().map_err(|never| match never {}).boxed());
    *response.status_mut() = status;
    response
}
