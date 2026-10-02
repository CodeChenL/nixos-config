use crate::{
    handshake, pool,
    relay::{self, ClientEndpoint},
    server::State,
    transport::{self, SETUP_TIMEOUT},
};
use fast_socks5::util::target_addr::read_address;
use std::{net::SocketAddr, sync::Arc};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    time::timeout,
};

pub async fn serve(mut stream: TcpStream, state: Arc<State>) -> anyhow::Result<()> {
    let peer = stream.peer_addr()?;
    let local = stream.local_addr()?;
    let Some(credentials) = timeout(SETUP_TIMEOUT, handshake::credentials(&mut stream)).await??
    else {
        return Ok(());
    };
    if !state.auth.check(credentials).await {
        stream.write_all(&[1, 255]).await?;
        return Ok(());
    }
    stream.write_all(&[1, 0]).await?;
    let request = timeout(SETUP_TIMEOUT, async {
        let mut header = [0; 4];
        stream.read_exact(&mut header).await?;
        let [version, command, reserved, address_type] = header;
        anyhow::ensure!(
            version == 5 && reserved == 0,
            "Invalid SOCKS command header"
        );
        let target = read_address(&mut stream, address_type).await?;
        Ok::<_, anyhow::Error>((command, target))
    })
    .await;
    let Ok(Ok((command, target))) = request else {
        reply(&mut stream, 1, local).await?;
        return Ok(());
    };
    match command {
        1 => match transport::dial(&target).await {
            Ok(mut target) => {
                reply(&mut stream, 0, target.local_addr()?).await?;
                transport::copy_bidirectional(&mut stream, &mut target).await?;
            }
            Err(_) => reply(&mut stream, 1, local).await?,
        },
        2 => reply(&mut stream, 2, local).await?,
        3 => {
            let Ok(requested) = transport::resolve(&target).await else {
                reply(&mut stream, 1, local).await?;
                return Ok(());
            };
            let Ok(endpoint) = ClientEndpoint::new(peer, requested) else {
                reply(&mut stream, 2, local).await?;
                return Ok(());
            };
            match pool::bind(local.ip(), &state.config.udp.port_range).await {
                Ok(socket) => {
                    let advertised = SocketAddr::new(
                        state.config.udp.public_address,
                        socket.local_addr()?.port(),
                    );
                    reply(&mut stream, 0, advertised).await?;
                    relay::run(stream, socket, endpoint).await?;
                }
                Err(_) => reply(&mut stream, 1, local).await?,
            }
        }
        _ => reply(&mut stream, 7, local).await?,
    }
    Ok(())
}

async fn reply(stream: &mut TcpStream, code: u8, address: SocketAddr) -> anyhow::Result<()> {
    let mut response = vec![5, code, 0];
    match address {
        SocketAddr::V4(address) => {
            response.push(1);
            response.extend_from_slice(&address.ip().octets());
        }
        SocketAddr::V6(address) => {
            response.push(4);
            response.extend_from_slice(&address.ip().octets());
        }
    }
    response.extend_from_slice(&address.port().to_be_bytes());
    stream.write_all(&response).await?;
    Ok(())
}
