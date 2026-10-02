use crate::transport::{self, SETUP_TIMEOUT};
use bytes::Bytes;
use fast_socks5::{new_udp_header, parse_udp_request};
use std::{
    collections::HashMap,
    io,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::AsyncReadExt,
    net::{TcpStream, UdpSocket},
    sync::mpsc,
    task::JoinSet,
    time::timeout,
};

const MAX_TARGETS: usize = 256;
const TARGET_IDLE: Duration = Duration::from_secs(60);

pub struct ClientEndpoint {
    peer_ip: IpAddr,
    pinned: Option<SocketAddr>,
}

impl ClientEndpoint {
    pub(crate) fn new(peer: SocketAddr, requested: SocketAddr) -> io::Result<Self> {
        if !requested.ip().is_unspecified() && requested.ip() != peer.ip() {
            return Err(io::Error::from(io::ErrorKind::PermissionDenied));
        }
        Ok(Self {
            peer_ip: peer.ip(),
            pinned: (requested.port() != 0).then(|| SocketAddr::new(peer.ip(), requested.port())),
        })
    }

    pub(crate) fn accepts(&self, source: SocketAddr) -> bool {
        source.ip() == self.peer_ip && self.pinned.is_none_or(|endpoint| endpoint == source)
    }
}

pub async fn run(
    mut control: TcpStream,
    relay: UdpSocket,
    mut endpoint: ClientEndpoint,
) -> anyhow::Result<()> {
    let relay = Arc::new(relay);
    let mut tasks = JoinSet::new();
    let mut control_byte = [0];
    let result = tokio::select! {
        closed = control.read(&mut control_byte) => closed.map(|_| ()).map_err(anyhow::Error::from),
        result = packets(&relay, &mut endpoint, &mut tasks) => result,
    };
    tasks.shutdown().await;
    result
}

async fn packets(
    relay: &Arc<UdpSocket>,
    endpoint: &mut ClientEndpoint,
    tasks: &mut JoinSet<anyhow::Result<()>>,
) -> anyhow::Result<()> {
    let mut targets: HashMap<SocketAddr, mpsc::Sender<Bytes>> = HashMap::new();
    let mut buffer = vec![0; 65535];
    loop {
        let (length, source) = tokio::select! {
            received = relay.recv_from(&mut buffer) => received?,
            result = tasks.join_next(), if !tasks.is_empty() => {
                match result { Some(Ok(Ok(()))) | None => (), Some(Ok(Err(_)) | Err(_)) => tracing::debug!("UDP upstream ended") }
                targets.retain(|_, sender| !sender.is_closed());
                continue;
            }
        };
        if !endpoint.accepts(source) {
            continue;
        }
        let Ok((0, target, payload)) = parse_udp_request(&buffer[..length]).await else {
            continue;
        };
        let Ok(address) = transport::resolve(&target).await else {
            continue;
        };
        if address.port() == 0 {
            continue;
        }
        while let Some(result) = tasks.try_join_next() {
            if !matches!(result, Ok(Ok(()))) {
                tracing::debug!("UDP upstream ended");
            }
        }
        targets.retain(|_, sender| !sender.is_closed());
        let mut packet = Bytes::copy_from_slice(payload);
        if let Some(sender) = targets.get(&address) {
            match sender.try_send(packet) {
                Ok(()) => {
                    endpoint.pinned = Some(source);
                    continue;
                }
                Err(mpsc::error::TrySendError::Full(_)) => continue,
                Err(mpsc::error::TrySendError::Closed(returned)) => packet = returned,
            }
            targets.remove(&address);
        }
        if targets.len() >= MAX_TARGETS {
            continue;
        }
        let bind_ip = match address {
            SocketAddr::V4(_) => IpAddr::V4(Ipv4Addr::UNSPECIFIED),
            SocketAddr::V6(_) => IpAddr::V6(Ipv6Addr::UNSPECIFIED),
        };
        let Ok(socket) = UdpSocket::bind(SocketAddr::new(bind_ip, 0)).await else {
            continue;
        };
        if !matches!(
            timeout(SETUP_TIMEOUT, socket.connect(address)).await,
            Ok(Ok(()))
        ) {
            continue;
        }
        let (sender, receiver) = mpsc::channel(16);
        let Ok(()) = sender.try_send(packet) else {
            continue;
        };
        let frontend = Arc::clone(relay);
        tasks.spawn(upstream(socket, receiver, (frontend, source, address)));
        targets.insert(address, sender);
        endpoint.pinned = Some(source);
    }
}

async fn upstream(
    socket: UdpSocket,
    mut packets: mpsc::Receiver<Bytes>,
    destination: (Arc<UdpSocket>, SocketAddr, SocketAddr),
) -> anyhow::Result<()> {
    let (relay, client, origin) = destination;
    let header = new_udp_header(origin)?;
    let mut buffer = vec![0; 65535];
    loop {
        let activity = timeout(TARGET_IDLE, async {
            let open = tokio::select! {
                packet = packets.recv() => {
                    match packet { Some(packet) => { socket.send(&packet).await?; true }, None => false }
                }
                received = socket.recv(&mut buffer) => {
                    let length = received?;
                    let mut reply = Vec::with_capacity(header.len() + length);
                    reply.extend_from_slice(&header);
                    reply.extend_from_slice(&buffer[..length]);
                    relay.send_to(&reply, client).await?;
                    true
                }
            };
            Ok::<_, anyhow::Error>(open)
        }).await;
        match activity {
            Ok(Ok(true)) => (),
            Ok(Ok(false)) | Err(_) => return Ok(()),
            Ok(Err(error)) => return Err(error),
        }
    }
}

#[cfg(test)]
#[path = "../tests/relay.rs"]
mod tests;
