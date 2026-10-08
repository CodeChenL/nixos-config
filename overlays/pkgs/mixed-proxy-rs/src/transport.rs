use crate::config::Tls;
use anyhow::Context;
use fast_socks5::util::target_addr::TargetAddr;
use rustls::{ClientConfig, RootCertStore, ServerConfig, pki_types::ServerName};
use std::{
    net::SocketAddr,
    pin::Pin,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    task::{Context as TaskContext, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::{TcpStream, lookup_host},
    time::{Instant, timeout},
};
use tokio_rustls::{TlsAcceptor, TlsConnector};

pub const SETUP_TIMEOUT: Duration = Duration::from_secs(10);
const COPY_BUF_SIZE: usize = 65536;
/// Close a tunnel that stays completely idle this long after either peer
/// half-closed it. Data keeps flowing while the surviving peer is active;
/// only abandoned half-open connections are reaped so they cannot pin file
/// descriptors forever.
const HALF_CLOSE_LINGER: Duration = Duration::from_secs(600);

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

#[derive(Default)]
struct TunnelActivity {
    half_closed: AtomicBool,
    last_activity: Mutex<Option<Instant>>,
}

impl TunnelActivity {
    fn touch(&self) {
        let now = Instant::now();
        match self.last_activity.lock() {
            Ok(mut last) => *last = Some(now),
            Err(poisoned) => *poisoned.into_inner() = Some(now),
        }
    }

    fn idle(&self) -> Option<Duration> {
        let last = match self.last_activity.lock() {
            Ok(last) => *last,
            Err(poisoned) => *poisoned.into_inner(),
        };
        last.map(|instant| instant.elapsed())
    }
}

struct Monitored<T> {
    stream: T,
    activity: Arc<TunnelActivity>,
}

impl<T: AsyncRead + Unpin> AsyncRead for Monitored<T> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        context: &mut TaskContext<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let activity = Arc::clone(&self.activity);
        let before = buffer.filled().len();
        let ready = Pin::new(&mut self.stream).poll_read(context, buffer);
        if matches!(&ready, Poll::Ready(Ok(()))) {
            if buffer.filled().len() == before {
                activity.half_closed.store(true, Ordering::SeqCst);
            }
            activity.touch();
        }
        ready
    }
}

impl<T: AsyncWrite + Unpin> AsyncWrite for Monitored<T> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        context: &mut TaskContext<'_>,
        buffer: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        let ready = Pin::new(&mut self.stream).poll_write(context, buffer);
        if matches!(&ready, Poll::Ready(Ok(written)) if *written > 0) {
            self.activity.touch();
        }
        ready
    }

    fn poll_flush(
        mut self: Pin<&mut Self>,
        context: &mut TaskContext<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.stream).poll_flush(context)
    }

    fn poll_shutdown(
        mut self: Pin<&mut Self>,
        context: &mut TaskContext<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.stream).poll_shutdown(context)
    }
}

async fn reap_half_closed(activity: Arc<TunnelActivity>, linger: Duration) {
    let interval = (linger / 4).max(Duration::from_secs(1));
    loop {
        tokio::time::sleep(interval).await;
        if !activity.half_closed.load(Ordering::SeqCst) {
            continue;
        }
        if let Some(idle) = activity.idle() {
            if idle >= linger {
                return;
            }
        }
    }
}

pub async fn copy_bidirectional<A, B>(a: &mut A, b: &mut B) -> std::io::Result<(u64, u64)>
where
    A: AsyncRead + AsyncWrite + Unpin + ?Sized,
    B: AsyncRead + AsyncWrite + Unpin + ?Sized,
{
    copy_bidirectional_with_linger(a, b, HALF_CLOSE_LINGER).await
}

#[allow(clippy::needless_pass_by_ref_mut)] // &mut A is only reborrowed into the monitored stream wrappers.
pub async fn copy_bidirectional_with_linger<A, B>(
    a: &mut A,
    b: &mut B,
    linger: Duration,
) -> std::io::Result<(u64, u64)>
where
    A: AsyncRead + AsyncWrite + Unpin + ?Sized,
    B: AsyncRead + AsyncWrite + Unpin + ?Sized,
{
    let activity = Arc::new(TunnelActivity::default());
    let mut first = Monitored {
        stream: a,
        activity: Arc::clone(&activity),
    };
    let mut second = Monitored {
        stream: b,
        activity: Arc::clone(&activity),
    };
    let copy = tokio::io::copy_bidirectional_with_sizes(
        &mut first,
        &mut second,
        COPY_BUF_SIZE,
        COPY_BUF_SIZE,
    );
    let reaper = reap_half_closed(activity, linger);
    tokio::pin!(copy);
    tokio::pin!(reaper);
    tokio::select! {
        result = &mut copy => result,
        () = &mut reaper => Ok((0, 0)),
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
