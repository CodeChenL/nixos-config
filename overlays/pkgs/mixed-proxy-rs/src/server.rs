use crate::{
    auth::Authenticator,
    config::Config,
    http, socks,
    transport::{SETUP_TIMEOUT, TlsState},
};
use std::sync::Arc;
use tokio::{
    net::{TcpListener, TcpStream},
    sync::watch,
    task::JoinSet,
    time::timeout,
};

pub struct State {
    pub(crate) auth: Authenticator,
    pub(crate) config: Config,
    pub(crate) tls: TlsState,
}

pub async fn run(
    listener: TcpListener,
    state: Arc<State>,
    mut shutdown: watch::Receiver<bool>,
) -> anyhow::Result<()> {
    let mut connections = JoinSet::new();
    let result = loop {
        tokio::select! {
            biased;
            _ = shutdown.changed() => break Ok(()),
            completed = connections.join_next(), if !connections.is_empty() => {
                if let Some(Err(error)) = completed { tracing::error!(cancelled = error.is_cancelled(), "Connection task failed"); }
            }
            incoming = listener.accept() => {
                let (stream, peer) = match incoming { Ok(incoming) => incoming, Err(error) => break Err(error.into()) };
                let state = Arc::clone(&state);
                connections.spawn(async move {
                    if connection(stream, state).await.is_err() { tracing::debug!(%peer, "Proxy connection ended"); }
                });
            }
        }
    };
    timeout(std::time::Duration::from_secs(2), connections.shutdown()).await?;
    result
}

async fn connection(stream: TcpStream, state: Arc<State>) -> anyhow::Result<()> {
    let mut byte = [0];
    if timeout(SETUP_TIMEOUT, stream.peek(&mut byte)).await?? == 0 {
        return Ok(());
    }
    match byte {
        [5] => socks::serve(stream, state).await,
        [22] => {
            let tls = timeout(SETUP_TIMEOUT, state.tls.acceptor.accept(stream)).await??;
            http::serve(tls, state).await
        }
        [_] => Ok(()),
    }
}
