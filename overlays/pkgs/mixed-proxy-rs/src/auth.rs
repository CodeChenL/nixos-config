use crate::credentials::Credentials;
use pam_client2::{Context, Flag, conv_mock::Conversation};
use std::{sync::Arc, time::Duration};
use tokio::{
    sync::{OwnedSemaphorePermit, Semaphore},
    time::{Instant, timeout_at},
};

const USER: &str = "chen";
const SERVICE: &str = "mixed-proxy";
pub const WORKERS: usize = 16;
const DEADLINE: Duration = Duration::from_secs(10);

pub trait AuthBackend: Send + Sync {
    fn check(&self, credentials: &Credentials) -> pam_client2::Result<bool>;
}

struct NativePam;

impl AuthBackend for NativePam {
    fn check(&self, credentials: &Credentials) -> pam_client2::Result<bool> {
        let conversation = Conversation::with_credentials(
            credentials.username.as_str(),
            credentials.password.as_str(),
        );
        let mut context = Context::new(SERVICE, Some(USER), conversation)?;
        context.authenticate(Flag::NONE)?;
        context.acct_mgmt(Flag::NONE)?;
        let accepted = context.user()? == USER;
        drop(context);
        Ok(accepted)
    }
}

pub struct Authenticator {
    backend: Arc<dyn AuthBackend>,
    permits: Arc<Semaphore>,
}

impl Authenticator {
    pub fn new() -> Self {
        Self {
            backend: Arc::new(NativePam),
            permits: Arc::new(Semaphore::new(WORKERS)),
        }
    }

    #[cfg(test)]
    pub fn with_backend(backend: Arc<dyn AuthBackend>) -> Self {
        Self {
            backend,
            permits: Arc::new(Semaphore::new(WORKERS)),
        }
    }

    pub async fn check(&self, credentials: Credentials) -> bool {
        if credentials.username != USER {
            return false;
        }
        let deadline = Instant::now() + DEADLINE;
        let Ok(Ok(permit)) = timeout_at(deadline, Arc::clone(&self.permits).acquire_owned()).await
        else {
            return false;
        };
        if Instant::now() >= deadline {
            return false;
        }
        let backend = Arc::clone(&self.backend);
        let worker = tokio::task::spawn_blocking(move || {
            let _permit: OwnedSemaphorePermit = permit;
            if Instant::now() >= deadline {
                return Ok(false);
            }
            backend.check(&credentials)
        });
        matches!(timeout_at(deadline, worker).await, Ok(Ok(Ok(true)))) && Instant::now() < deadline
    }
}

#[cfg(test)]
#[path = "../tests/auth_lifecycle.rs"]
mod lifecycle_tests;
