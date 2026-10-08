use crate::transport;
use rustls::{
    ClientConfig, RootCertStore, ServerConfig,
    pki_types::{PrivatePkcs8KeyDer, ServerName},
};
use std::{sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    time::timeout,
};
use tokio_rustls::{TlsAcceptor, TlsConnector};

#[tokio::test]
async fn flushes_tls_after_backpressure_without_waiting_for_more_data_or_eof() {
    let certificate = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()]).unwrap();
    let cert = certificate.cert.der().clone();
    let key = PrivatePkcs8KeyDer::from(certificate.signing_key.serialize_der());
    let mut server_config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert.clone()], key.into())
        .unwrap();
    server_config.send_tls13_tickets = 0;
    let acceptor = TlsAcceptor::from(Arc::new(server_config));
    let mut roots = RootCertStore::empty();
    roots.add(cert).unwrap();
    let connector = TlsConnector::from(Arc::new(
        ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth(),
    ));
    let (server_io, client_io) = tokio::io::duplex(64);
    let (server, client) = timeout(Duration::from_secs(1), async {
        tokio::join!(
            acceptor.accept(server_io),
            connector.connect(ServerName::try_from("localhost").unwrap(), client_io)
        )
    })
    .await
    .unwrap();
    let mut server = server.unwrap();
    let mut client = client.unwrap();
    let (mut origin, mut outbound) = tokio::io::duplex(4096);
    let worker =
        tokio::spawn(
            async move { transport::copy_bidirectional(&mut server, &mut outbound).await },
        );
    let payload = [0x61; 1024];
    origin.write_all(&payload).await.unwrap();
    let mut received = [0; 1024];
    let result = timeout(Duration::from_secs(1), client.read_exact(&mut received)).await;
    worker.abort();
    assert!(worker.await.unwrap_err().is_cancelled());
    result.unwrap().unwrap();
    assert_eq!(received, payload);
}

#[tokio::test(start_paused = true)]
async fn closes_half_closed_tunnel_after_idle_linger() {
    let linger = Duration::from_secs(300);
    let (mut client, mut client_peer) = tokio::io::duplex(1024);
    let (mut target, mut target_peer) = tokio::io::duplex(1024);
    let task = tokio::spawn(async move {
        transport::copy_bidirectional_with_linger(&mut client, &mut target, linger).await
    });
    client_peer.write_all(b"ping").await.unwrap();
    let mut received = [0; 4];
    target_peer.read_exact(&mut received).await.unwrap();
    assert_eq!(&received, b"ping");
    client_peer.shutdown().await.unwrap();
    tokio::task::yield_now().await;
    assert!(
        !task.is_finished(),
        "tunnel closed before the linger elapsed"
    );
    let result = task.await.unwrap().unwrap();
    assert_eq!(result, (0, 0));
}

#[tokio::test]
async fn keeps_half_closed_tunnel_open_while_peer_stays_active() {
    let linger = Duration::from_millis(600);
    let (mut client, mut client_peer) = tokio::io::duplex(1024);
    let (mut target, mut target_peer) = tokio::io::duplex(1024);
    let task = tokio::spawn(async move {
        transport::copy_bidirectional_with_linger(&mut client, &mut target, linger).await
    });
    client_peer.write_all(b"hello").await.unwrap();
    let mut received = [0; 5];
    target_peer.read_exact(&mut received).await.unwrap();
    client_peer.shutdown().await.unwrap();
    for _ in 0..8 {
        tokio::time::sleep(Duration::from_millis(150)).await;
        target_peer.write_all(b"x").await.unwrap();
    }
    assert!(!task.is_finished(), "active half-closed tunnel was reaped");
    let result = tokio::time::timeout(Duration::from_secs(6), task)
        .await
        .expect("idle half-closed tunnel was not reaped")
        .unwrap()
        .unwrap();
    assert_eq!(result, (0, 0));
}
