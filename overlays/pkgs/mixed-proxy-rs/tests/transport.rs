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
