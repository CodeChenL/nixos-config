use serde::Deserialize;
use std::{
    net::{IpAddr, SocketAddr},
    num::NonZeroU16,
    ops::RangeInclusive,
    path::PathBuf,
};

#[derive(Debug, Deserialize)]
#[serde(try_from = "RawRange")]
pub struct PortRange {
    from: NonZeroU16,
    to: NonZeroU16,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawRange {
    from: NonZeroU16,
    to: NonZeroU16,
}

impl TryFrom<RawRange> for PortRange {
    type Error = &'static str;
    fn try_from(value: RawRange) -> Result<Self, Self::Error> {
        if value.from > value.to {
            return Err("UDP port range is reversed");
        }
        Ok(Self {
            from: value.from,
            to: value.to,
        })
    }
}

impl PortRange {
    pub(crate) const fn ports(&self) -> RangeInclusive<u16> {
        self.from.get()..=self.to.get()
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Config {
    pub(crate) listen: SocketAddr,
    pub(crate) tls: Tls,
    pub(crate) udp: Udp,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Tls {
    pub(crate) cert_file: PathBuf,
    pub(crate) key_file: PathBuf,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Udp {
    pub(crate) public_address: IpAddr,
    pub(crate) port_range: PortRange,
}

#[cfg(test)]
#[path = "../tests/config.rs"]
mod tests;
