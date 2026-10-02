use crate::{
    auth::Authenticator,
    auth_support::{FakeBackend, Reply},
    config::Config,
    credentials::Credentials,
    server::{self, State},
    transport::TlsState,
};
use rustls::{
    ClientConfig, RootCertStore, ServerConfig,
    pki_types::{PrivatePkcs8KeyDer, ServerName},
};
use std::{net::SocketAddr, sync::Arc};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::{mpsc, watch},
    task::JoinSet,
};
use tokio_rustls::{TlsAcceptor, TlsConnector, client::TlsStream};

pub struct Proxy {
    pub(crate) address: SocketAddr,
    pub(crate) client: TlsConnector,
    pub(crate) auth_records: mpsc::Receiver<Credentials>,
    pub(crate) shutdown: watch::Sender<bool>,
    pub(crate) tasks: JoinSet<()>,
}

impl Proxy {
    pub(crate) async fn start(reply: Reply) -> Self {
        let (backend, records) = FakeBackend::new(reply);
        Self::with_auth(Authenticator::with_backend(backend), records).await
    }

    pub(crate) async fn with_auth(
        auth: Authenticator,
        auth_records: mpsc::Receiver<Credentials>,
    ) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let mut tasks = JoinSet::new();
        let certificate = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()]).unwrap();
        let cert = certificate.cert.der().clone();
        let key = PrivatePkcs8KeyDer::from(certificate.signing_key.serialize_der());
        let server_tls = ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![cert.clone()], key.into())
            .unwrap();
        let mut roots = RootCertStore::empty();
        roots.add(cert).unwrap();
        let connector = TlsConnector::from(Arc::new(
            ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth(),
        ));
        let config: Config = serde_json::from_str(&format!(r#"{{"listen":"{address}","tls":{{"certFile":"unused","keyFile":"unused"}},"udp":{{"publicAddress":"47.254.74.103","portRange":{{"from":20000,"to":20127}}}}}}"#)).unwrap();
        let state = Arc::new(State {
            auth,
            config,
            tls: TlsState {
                acceptor: TlsAcceptor::from(Arc::new(server_tls)),
                connector: connector.clone(),
            },
        });
        let (shutdown, receiver) = watch::channel(false);
        tasks.spawn(async move {
            server::run(listener, state, receiver).await.unwrap();
        });
        Self {
            address,
            client: connector,
            auth_records,
            shutdown,
            tasks,
        }
    }

    pub(crate) async fn tls(&self) -> TlsStream<TcpStream> {
        self.client
            .connect(
                ServerName::try_from("localhost").unwrap(),
                TcpStream::connect(self.address).await.unwrap(),
            )
            .await
            .unwrap()
    }

    pub(crate) async fn stop(mut self) {
        self.shutdown.send(true).unwrap();
        self.tasks.join_next().await.unwrap().unwrap();
        self.tasks.shutdown().await;
    }
}
