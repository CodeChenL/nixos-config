use std::{
    io,
    net::{IpAddr, SocketAddr},
};
use tokio::net::UdpSocket;

use crate::config::PortRange;

pub async fn bind(ip: IpAddr, range: &PortRange) -> io::Result<UdpSocket> {
    for port in range.ports() {
        match UdpSocket::bind(SocketAddr::new(ip, port)).await {
            Ok(socket) => return Ok(socket),
            Err(error) if error.kind() == io::ErrorKind::AddrInUse => (),
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::from(io::ErrorKind::AddrInUse))
}

#[cfg(test)]
#[path = "../tests/pool.rs"]
mod tests;
