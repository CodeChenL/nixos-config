use crate::{auth::AuthBackend, credentials::Credentials};
use pam_client2::{ErrorCode, Result};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
    mpsc,
};
use std::time::Duration;
use tokio::sync::{mpsc as async_mpsc, oneshot};

#[derive(Clone, Copy)]
pub enum Reply {
    Allow,
    Deny,
    Unavailable,
    AuthenticationFailed,
    AccountExpired,
    PasswordChangeRequired,
}

impl Reply {
    pub fn result(self) -> Result<bool> {
        match self {
            Self::Allow => Ok(true),
            Self::Deny => Ok(false),
            Self::Unavailable => Err(pam_client2::Error::from(ErrorCode::AUTHINFO_UNAVAIL)),
            Self::AuthenticationFailed => Err(pam_client2::Error::from(ErrorCode::AUTH_ERR)),
            Self::AccountExpired => Err(pam_client2::Error::from(ErrorCode::ACCT_EXPIRED)),
            Self::PasswordChangeRequired => {
                Err(pam_client2::Error::from(ErrorCode::NEW_AUTHTOK_REQD))
            }
        }
    }
}

pub struct FakeBackend {
    pub calls: AtomicUsize,
    records: async_mpsc::Sender<Credentials>,
    reply: Reply,
}

impl FakeBackend {
    pub fn new(reply: Reply) -> (Arc<Self>, async_mpsc::Receiver<Credentials>) {
        let (records, receiver) = async_mpsc::channel(64);
        (
            Arc::new(Self {
                calls: AtomicUsize::new(0),
                records,
                reply,
            }),
            receiver,
        )
    }
}

impl AuthBackend for FakeBackend {
    fn check(&self, credentials: &Credentials) -> Result<bool> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.records
            .try_send(Credentials {
                username: credentials.username.clone(),
                password: credentials.password.clone(),
            })
            .unwrap();
        self.reply.result()
    }
}

pub struct BlockedCall {
    release: mpsc::SyncSender<()>,
    finished: oneshot::Receiver<()>,
}

impl BlockedCall {
    pub async fn release(self) {
        self.release.send(()).unwrap();
        self.finished.await.unwrap();
    }
}

pub struct BlockingBackend {
    started: async_mpsc::Sender<BlockedCall>,
}

struct BlockingContext(mpsc::Receiver<()>);

impl Drop for BlockingContext {
    fn drop(&mut self) {
        match self.0.recv_timeout(Duration::from_secs(5)) {
            Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => (),
            Err(mpsc::RecvTimeoutError::Timeout) => panic!("test context was not released"),
        }
    }
}

impl BlockingBackend {
    pub fn new() -> (Arc<Self>, async_mpsc::Receiver<BlockedCall>) {
        let (started, receiver) = async_mpsc::channel(4);
        (Arc::new(Self { started }), receiver)
    }
}

impl AuthBackend for BlockingBackend {
    fn check(&self, _credentials: &Credentials) -> Result<bool> {
        let (release, gate) = mpsc::sync_channel(1);
        let (finished, receiver) = oneshot::channel();
        self.started
            .blocking_send(BlockedCall {
                release,
                finished: receiver,
            })
            .unwrap();
        let context = BlockingContext(gate);
        drop(context);
        let _ = finished.send(());
        Ok(true)
    }
}
