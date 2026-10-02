use crate::{
    auth::Authenticator,
    auth_support::{FakeBackend, Reply},
    credentials::Credentials,
};
use std::sync::{Arc, atomic::Ordering};

#[tokio::test]
async fn rejects_other_users_when_backend_would_allow() {
    let (backend, _records) = FakeBackend::new(Reply::Allow);
    let auth = Authenticator::with_backend(backend.clone());
    let accepted = auth
        .check(Credentials::parse(b"root", b"synthetic").unwrap())
        .await;
    assert!(!accepted);
    assert_eq!(backend.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn checks_each_password_when_credentials_are_reused() {
    let (backend, mut records) = FakeBackend::new(Reply::Allow);
    let auth = Arc::new(Authenticator::with_backend(backend.clone()));
    for password in [b"first".as_slice(), b"second"] {
        let accepted = auth
            .check(Credentials::parse(b"chen", password).unwrap())
            .await;
        assert!(accepted);
        let recorded = records.recv().await.unwrap();
        assert_eq!(recorded.username, "chen");
        assert_eq!(recorded.password.as_bytes(), password);
    }
    assert_eq!(backend.calls.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn denies_when_backend_or_either_pam_stage_fails() {
    for reply in [
        Reply::Deny,
        Reply::Unavailable,
        Reply::AuthenticationFailed,
        Reply::AccountExpired,
        Reply::PasswordChangeRequired,
    ] {
        let (backend, _records) = FakeBackend::new(reply);
        let auth = Authenticator::with_backend(backend);
        let accepted = auth
            .check(Credentials::parse(b"chen", b"synthetic").unwrap())
            .await;
        assert!(!accepted);
    }
}
