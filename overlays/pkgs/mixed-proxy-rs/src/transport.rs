use crate::config::Tls;
use anyhow::Context;
use fast_socks5::util::target_addr::TargetAddr;
use rustls::{ClientConfig, RootCertStore, ServerConfig, pki_types::ServerName};
use std::{net::SocketAddr, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::{TcpStream, lookup_host},
    time::timeout,
};
use tokio_rustls::{TlsAcceptor, TlsConnector};

pub const SETUP_TIMEOUT: Duration = Duration::from_secs(10);
const COPY_BUF_SIZE: usize = 65536;

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
    let socket = timeout(SETUP_TIMEOUT, connect).await??;
    socket.set_nodelay(true)?;
    Ok(socket)
}

pub trait Stream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Stream for T {}

pub async fn copy_bidirectional<A, B>(a: &mut A, b: &mut B) -> std::io::Result<(u64, u64)>
where
    A: AsyncRead + AsyncWrite + Unpin + ?Sized,
    B: AsyncRead + AsyncWrite + Unpin + ?Sized,
{
    let (mut ar, mut aw) = tokio::io::split(a);
    let (mut br, mut bw) = tokio::io::split(b);
    let mut ab_buf = vec![0u8; COPY_BUF_SIZE];
    let mut ba_buf = vec![0u8; COPY_BUF_SIZE];
    let a_to_b = copy_one_way(&mut ar, &mut bw, &mut ab_buf);
    let b_to_a = copy_one_way(&mut br, &mut aw, &mut ba_buf);
    tokio::try_join!(a_to_b, b_to_a)
}

async fn copy_one_way<R, W>(reader: &mut R, writer: &mut W, buf: &mut [u8]) -> std::io::Result<u64>
where
    R: AsyncRead + Unpin + ?Sized,
    W: AsyncWrite + Unpin + ?Sized,
{
    let mut total = 0u64;
    loop {
        let n = reader.read(buf).await?;
        if n == 0 {
            writer.shutdown().await?;
            return Ok(total);
        }
        writer.write_all(&buf[..n]).await?;
        total += n as u64;
    }
}

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
