use base64::{Engine, engine::general_purpose::STANDARD};
use hyper::{HeaderMap, header::PROXY_AUTHORIZATION};
use std::fmt;

#[derive(thiserror::Error, Debug)]
#[error("Invalid proxy credentials")]
pub struct InvalidCredentials;

pub struct Credentials {
    pub(crate) username: String,
    pub(crate) password: String,
}

impl fmt::Debug for Credentials {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("Credentials([REDACTED])")
    }
}

impl Credentials {
    pub(crate) fn parse(username: &[u8], password: &[u8]) -> Result<Self, InvalidCredentials> {
        fn text(bytes: &[u8]) -> Result<String, InvalidCredentials> {
            if bytes.is_empty()
                || bytes.contains(&0)
                || bytes.contains(&b'\r')
                || bytes.contains(&b'\n')
            {
                return Err(InvalidCredentials);
            }
            std::str::from_utf8(bytes)
                .map(str::to_owned)
                .map_err(|_| InvalidCredentials)
        }
        Ok(Self {
            username: text(username)?,
            password: text(password)?,
        })
    }

    pub(crate) fn basic(headers: &HeaderMap) -> Result<Self, InvalidCredentials> {
        let mut values = headers.get_all(PROXY_AUTHORIZATION).iter();
        let header = values
            .next()
            .ok_or(InvalidCredentials)?
            .to_str()
            .map_err(|_| InvalidCredentials)?;
        if values.next().is_some() || header.len() > 2048 {
            return Err(InvalidCredentials);
        }
        let (scheme, encoded) = header.split_once(' ').ok_or(InvalidCredentials)?;
        if !scheme.eq_ignore_ascii_case("Basic") {
            return Err(InvalidCredentials);
        }
        let decoded = STANDARD.decode(encoded).map_err(|_| InvalidCredentials)?;
        let separator = decoded
            .iter()
            .position(|byte| *byte == b':')
            .ok_or(InvalidCredentials)?;
        let (username, rest) = decoded.split_at(separator);
        let password = rest.get(1..).ok_or(InvalidCredentials)?;
        Self::parse(username, password)
    }
}

#[cfg(test)]
#[path = "../tests/credentials.rs"]
mod tests;
