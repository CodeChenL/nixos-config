use crate::credentials::Credentials;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub async fn credentials<T: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut T,
) -> anyhow::Result<Option<Credentials>> {
    let version = stream.read_u8().await?;
    let count = stream.read_u8().await?;
    let mut methods = vec![0; usize::from(count)];
    stream.read_exact(&mut methods).await?;
    if version != 5 || !methods.contains(&2) {
        stream.write_all(&[5, 255]).await?;
        return Ok(None);
    }
    stream.write_all(&[5, 2]).await?;
    let auth_version = stream.read_u8().await?;
    let username_len = stream.read_u8().await?;
    let mut username = vec![0; usize::from(username_len)];
    stream.read_exact(&mut username).await?;
    let password_len = stream.read_u8().await?;
    let mut password = vec![0; usize::from(password_len)];
    stream.read_exact(&mut password).await?;
    match Credentials::parse(&username, &password) {
        Ok(credentials) if auth_version == 1 => Ok(Some(credentials)),
        Ok(_) | Err(_) => {
            stream.write_all(&[1, 255]).await?;
            Ok(None)
        }
    }
}

#[cfg(test)]
#[path = "../tests/handshake.rs"]
mod tests;
