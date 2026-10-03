mod auth;
mod config;
mod credentials;
mod handshake;
mod headers;
mod http;
mod pool;
mod relay;
mod server;
mod socks;
mod transport;

#[cfg(test)]
#[path = "../tests/support.rs"]
mod support;

#[cfg(test)]
#[path = "../tests/auth_support.rs"]
mod auth_support;

#[cfg(test)]
#[path = "../tests/http.rs"]
mod http_tests;

#[cfg(test)]
#[path = "../tests/socks.rs"]
mod socks_tests;

#[cfg(test)]
#[path = "../tests/auth.rs"]
mod auth_tests;

#[cfg(test)]
#[path = "../tests/auth_protocol.rs"]
mod auth_protocol_tests;

#[cfg(test)]
#[path = "../tests/auth_queue.rs"]
mod auth_queue_tests;

#[cfg(test)]
#[path = "../tests/transport.rs"]
mod transport_tests;

#[cfg(test)]
#[path = "../tests/streaming.rs"]
mod streaming_tests;

#[cfg(test)]
#[path = "../tests/udp_targets.rs"]
mod udp_target_tests;

#[cfg(test)]
#[path = "../tests/udp_rebind.rs"]
mod udp_rebind_tests;

#[cfg(test)]
#[path = "../tests/trailers.rs"]
mod trailer_tests;

#[cfg(test)]
#[path = "../tests/framing.rs"]
mod framing_tests;

use anyhow::Context;
use std::{path::PathBuf, sync::Arc, time::Duration};
use tokio::{
    net::TcpListener,
    signal::unix::{SignalKind, signal},
    sync::watch,
};

fn main() -> anyhow::Result<()> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("Creating proxy runtime")?;
    let result = runtime.block_on(run());
    runtime.shutdown_timeout(Duration::from_secs(2));
    result
}

async fn run() -> anyhow::Result<()> {
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    let path = match arguments.as_slice() {
        [flag] if flag == "--version" => {
            println!("mixed-proxy 0.1.0");
            return Ok(());
        }
        [flag] if flag == "--help" || flag == "-h" => {
            println!("Usage: mixed-proxy --config <JSON>\n       mixed-proxy --version");
            return Ok(());
        }
        [flag, path] if flag == "--config" => PathBuf::from(path),
        _ => anyhow::bail!("Usage: mixed-proxy --config <JSON>"),
    };
    tracing_subscriber::fmt()
        .json()
        .with_max_level(tracing::Level::INFO)
        .with_writer(std::io::stderr)
        .init();
    let config: config::Config =
        serde_json::from_slice(&std::fs::read(path).context("Reading proxy configuration")?)
            .context("Parsing proxy configuration")?;
    let tls = transport::TlsState::load(&config.tls).context("Loading TLS configuration")?;
    let listener = TcpListener::bind(config.listen)
        .await
        .context("Binding proxy listener")?;
    let listen = listener.local_addr()?;
    let mut terminate = signal(SignalKind::terminate())?;
    let (shutdown, receiver) = watch::channel(false);
    let state = Arc::new(server::State {
        config,
        tls,
        auth: auth::Authenticator::new(),
    });
    let server = server::run(listener, state, receiver);
    tokio::pin!(server);
    tracing::info!(%listen, "Proxy listener ready");
    tokio::select! {
        result = &mut server => result,
        _ = terminate.recv() => { shutdown.send(true)?; server.await }
        result = tokio::signal::ctrl_c() => { result?; shutdown.send(true)?; server.await }
    }
}
