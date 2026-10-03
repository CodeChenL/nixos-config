use crate::{
    auth::{Authenticator, WORKERS},
    auth_support::{BlockingBackend, assert_pending},
    credentials::Credentials,
};
use std::{sync::Arc, time::Duration};
use tokio::{runtime::Builder, task::JoinSet, time::timeout};

#[tokio::test]
async fn completes_thirty_two_authentications_with_sixteen_workers() {
    let (backend, mut started) = BlockingBackend::new();
    let auth = Arc::new(Authenticator::with_backend(backend));
    let mut tasks = JoinSet::new();
    for _ in 0..32 {
        let shared = Arc::clone(&auth);
        tasks.spawn(async move {
            shared
                .check(Credentials::parse(b"chen", b"test").unwrap())
                .await
        });
    }
    let mut active = Vec::new();
    for _ in 0..16 {
        active.push(
            timeout(Duration::from_secs(1), started.recv())
                .await
                .unwrap()
                .unwrap(),
        );
    }
    let extra = timeout(Duration::from_millis(100), started.recv()).await;
    for call in active {
        call.release().await;
    }
    for _ in 0..16 {
        timeout(Duration::from_secs(1), started.recv())
            .await
            .unwrap()
            .unwrap()
            .release()
            .await;
    }
    let mut successes = 0;
    while let Some(result) = tasks.join_next().await {
        successes += usize::from(result.unwrap());
    }
    assert!(extra.is_err());
    assert_eq!(successes, 32);
}

#[tokio::test]
async fn expired_queue_does_not_start_a_new_pam_call_when_a_permit_becomes_ready() {
    let (backend, mut started) = BlockingBackend::new();
    let auth = Arc::new(Authenticator::with_backend(backend));
    let mut tasks = JoinSet::new();
    let mut active = Vec::new();
    for _ in 0..WORKERS {
        let shared = Arc::clone(&auth);
        tasks.spawn(async move {
            shared
                .check(Credentials::parse(b"chen", b"test").unwrap())
                .await
        });
        active.push(started.recv().await.unwrap());
    }
    let mut queued = Box::pin(auth.check(Credentials::parse(b"chen", b"test").unwrap()));
    assert_pending(queued.as_mut()).await;
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(11)).await;
    while let Some(result) = tasks.join_next().await {
        assert!(!result.unwrap());
    }
    for call in active {
        call.release().await;
    }
    assert!(!queued.await);
    tokio::time::resume();
    let late = timeout(Duration::from_millis(100), started.recv()).await;
    let worker_started = matches!(&late, Ok(Some(_)));
    if let Ok(Some(call)) = late {
        call.release().await;
    }
    assert!(!worker_started, "expired queue started fresh PAM work");
}

#[test]
fn expired_blocking_queue_does_not_start_pam_when_worker_thread_becomes_available() {
    let runtime = Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(1)
        .build()
        .unwrap();
    runtime.block_on(async {
        let (release, gate) = std::sync::mpsc::sync_channel(1);
        let (entered, ready) = std::sync::mpsc::sync_channel(1);
        let blocker = tokio::task::spawn_blocking(move || {
            entered.send(()).unwrap();
            gate.recv_timeout(Duration::from_secs(5)).unwrap();
        });
        ready.recv_timeout(Duration::from_secs(5)).unwrap();
        let (backend, mut started) = BlockingBackend::new();
        let auth = Authenticator::with_backend(backend);
        let mut request = Box::pin(auth.check(Credentials::parse(b"chen", b"test").unwrap()));
        assert_pending(request.as_mut()).await;
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(11)).await;
        assert!(!request.await);
        tokio::time::resume();
        release.send(()).unwrap();
        blocker.await.unwrap();
        let late = timeout(Duration::from_millis(100), started.recv()).await;
        let worker_started = matches!(&late, Ok(Some(_)));
        if let Ok(Some(call)) = late {
            call.release().await;
        }
        assert!(
            !worker_started,
            "expired blocking job started fresh PAM work"
        );
    });
    runtime.shutdown_timeout(Duration::from_secs(2));
}
