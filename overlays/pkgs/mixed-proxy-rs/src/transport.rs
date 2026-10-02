use crate::config::Tls;
use anyhow::Context;
use fast_socks5::util::target_addr::TargetAddr;
use rustls::{ClientConfig, RootCertStore, ServerConfig, pki_types::ServerName};
use std::{net::SocketAddr, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::{TcpStream, lookup_host},
    time::timeout,
};
use tokio_rustls::{TlsAcceptor, TlsConnector};

pub const SETUP_TIMEOUT: Duration = Duration::from_secs(10);

pub struct TlsState {
    pub(crate) acceptor: TlsAcceptor,
    pub(crate) connector: TlsConnector,
}

impl TlsState {
    pub(crate) fn load(config: &Tls) -> anyhow::Result<Self> {
        let certificates = rustls_pemfile::certs(&mut std::io::BufReader::new(
            std::fs::File::open(&config.cert_file)?,
        ))
        .collect::<Result<Vec<_>, _>>()?;
        let key = rustls_pemfile::private_key(&mut std::io::BufReader::new(std::fs::File::open(
            &config.key_file,
        )?))?
        .context("TLS private key is missing")?;
        let mut server = ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(certificates, key)?;
        server.alpn_protocols = vec![b"http/1.1".to_vec()];
        let roots = webpki_roots::TLS_SERVER_ROOTS
            .iter()
            .cloned()
            .collect::<RootCertStore>();
        let client = ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        Ok(Self {
            acceptor: TlsAcceptor::from(Arc::new(server)),
            connector: TlsConnector::from(Arc::new(client)),
        })
    }
}

pub async fn resolve(target: &TargetAddr) -> anyhow::Result<SocketAddr> {
    match target {
        TargetAddr::Ip(address) => Ok(*address),
        TargetAddr::Domain(host, port) => {
            timeout(SETUP_TIMEOUT, lookup_host((host.as_str(), *port)))
                .await??
                .next()
                .context("DNS returned no addresses")
        }
    }
}

pub async fn dial(target: &TargetAddr) -> anyhow::Result<TcpStream> {
    let connect = async {
        match target {
            TargetAddr::Ip(address) => TcpStream::connect(address).await,
            TargetAddr::Domain(host, port) => TcpStream::connect((host.as_str(), *port)).await,
        }
    };
    Ok(timeout(SETUP_TIMEOUT, connect).await??)
}

pub trait Stream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Stream for T {}

pub async fn forward(
    target: &TargetAddr,
    tls: Option<&TlsConnector>,
) -> anyhow::Result<Box<dyn Stream>> {
    timeout(SETUP_TIMEOUT, async {
        let socket = dial(target).await?;
        match tls {
            None => Ok(Box::new(socket) as Box<dyn Stream>),
            Some(connector) => {
                let name = match target {
                    TargetAddr::Ip(address) => ServerName::from(address.ip()),
                    TargetAddr::Domain(host, _) => ServerName::try_from(host.clone())?,
                };
                Ok(Box::new(connector.connect(name, socket).await?) as Box<dyn Stream>)
            }
        }
    })
    .await?
}
