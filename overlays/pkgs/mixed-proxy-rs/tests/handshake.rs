use super::credentials;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    task::JoinSet,
    time::{Duration, timeout},
};

#[tokio::test]
async fn selects_password_when_greeting_is_only_three_fragmented_bytes() {
    let (mut client, mut server) = tokio::io::duplex(1024);
    let mut tasks = JoinSet::new();
    tasks.spawn(async move { credentials(&mut server).await });
    for fragment in [5, 1, 2] {
        client.write_all(&[fragment]).await.unwrap();
    }
    let mut selected = [0; 2];
    timeout(Duration::from_secs(1), client.read_exact(&mut selected))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(selected, [5, 2]);
    client.write_all(b"\x01\x04chen\x04test").await.unwrap();
    let result = tasks.join_next().await.unwrap().unwrap().unwrap().unwrap();
    assert_eq!(result.username, "chen");
}

#[tokio::test]
async fn refuses_no_auth_when_password_method_is_absent() {
    let (mut client, mut server) = tokio::io::duplex(1024);
    let mut tasks = JoinSet::new();
    tasks.spawn(async move { credentials(&mut server).await });
    client.write_all(&[5, 1, 0]).await.unwrap();
    let mut selected = [0; 2];
    client.read_exact(&mut selected).await.unwrap();
    assert_eq!(selected, [5, 255]);
    assert!(tasks.join_next().await.unwrap().unwrap().unwrap().is_none());
}

#[tokio::test]
async fn rejects_credentials_when_rfc1929_version_is_invalid() {
    let (mut client, mut server) = tokio::io::duplex(1024);
    let mut tasks = JoinSet::new();
    tasks.spawn(async move { credentials(&mut server).await });
    client.write_all(&[5, 2, 0, 2]).await.unwrap();
    let mut selected = [0; 2];
    client.read_exact(&mut selected).await.unwrap();
    assert_eq!(selected, [5, 2]);
    client.write_all(b"\x02\x04chen\x04test").await.unwrap();
    let mut rejected = [0; 2];
    client.read_exact(&mut rejected).await.unwrap();
    assert_eq!(rejected, [1, 255]);
    assert!(tasks.join_next().await.unwrap().unwrap().unwrap().is_none());
}
