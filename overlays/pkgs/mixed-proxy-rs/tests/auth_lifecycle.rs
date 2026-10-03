use super::{Authenticator, WORKERS};
use crate::{
    auth_support::{BlockingBackend, assert_pending},
    credentials::Credentials,
};
use std::{
    sync::{Arc, mpsc},
    time::Duration,
};
use tokio::{
    runtime::Builder,
    task::JoinSet,
    time::{advance, timeout},
};

fn credentials() -> Credentials {
    Credentials::parse(b"chen", b"synthetic").unwrap()
}

#[tokio::test]
async fn rejects_completed_success_when_deadline_elapsed_before_poll() {
    let (backend, mut started) = BlockingBackend::new();
    let auth = Authenticator::with_backend(backend);
    let mut request = Box::pin(auth.check(credentials()));
    assert_pending(request.as_mut()).await;
    let call = started.recv().await.unwrap();
    tokio::time::pause();
    advance(Duration::from_secs(10)).await;
    call.release().await;
    let restored = Arc::clone(&auth.permits)
        .acquire_many_owned(WORKERS.try_into().unwrap())
        .await
        .unwrap();
    drop(restored);
    let accepted = request.await;
    assert!(!accepted);
}

#[tokio::test]
async fn queues_when_all_context_destructors_hold_permits() {
    let (backend, mut started) = BlockingBackend::new();
    let auth = Arc::new(Authenticator::with_backend(backend));
    let mut tasks = JoinSet::new();
    let mut calls = Vec::new();
    for _ in 0..WORKERS {
        let shared = Arc::clone(&auth);
        tasks.spawn(async move { shared.check(credentials()).await });
        calls.push(started.recv().await.unwrap());
    }
    let mut queued = Box::pin(auth.check(credentials()));
    assert_pending(queued.as_mut()).await;
    drop(queued);
    for call in calls {
        call.release().await;
    }
    while let Some(result) = tasks.join_next().await {
        assert!(result.unwrap());
    }
    assert_eq!(auth.permits.available_permits(), WORKERS);
}

#[tokio::test]
async fn stops_network_when_context_destructors_remain_blocked() {
    use crate::support::Proxy;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpStream,
        sync::mpsc,
    };

    let (backend, mut started) = BlockingBackend::new();
    let (_records, receiver) = mpsc::channel(1);
    let proxy = Proxy::with_auth(Authenticator::with_backend(backend), receiver).await;
    let mut stream = TcpStream::connect(proxy.address).await.unwrap();
    stream
        .write_all(b"\x05\x01\x02\x01\x04chen\x04test")
        .await
        .unwrap();
    let call = started.recv().await.unwrap();
    let stopped = timeout(Duration::from_secs(2), proxy.stop()).await;
    let mut bytes = Vec::new();
    let closed = timeout(Duration::from_secs(1), stream.read_to_end(&mut bytes)).await;
    call.release().await;
    assert!(stopped.is_ok());
    closed.unwrap().unwrap();
    assert_eq!(bytes, [5, 2]);
}

#[tokio::test]
async fn retains_permits_and_rejects_late_success_when_deadline_expires() {
    let (backend, mut started) = BlockingBackend::new();
    let auth = Arc::new(Authenticator::with_backend(backend));
    let mut tasks = JoinSet::new();
    let mut calls = Vec::new();
    for _ in 0..WORKERS {
        let shared = Arc::clone(&auth);
        tasks.spawn(async move { shared.check(credentials()).await });
        calls.push(started.recv().await.unwrap());
    }
    tokio::time::pause();
    advance(Duration::from_secs(11)).await;
    while let Some(result) = tasks.join_next().await {
        assert!(!result.unwrap());
    }
    let remaining = auth.permits.available_permits();
    let mut overloaded_fut = Box::pin(auth.check(credentials()));
    assert_pending(overloaded_fut.as_mut()).await;
    drop(overloaded_fut);
    for call in calls {
        call.release().await;
    }
    let restored = Arc::clone(&auth.permits)
        .acquire_many_owned(WORKERS.try_into().unwrap())
        .await
        .unwrap();
    drop(restored);
    tokio::time::resume();
    let shared = Arc::clone(&auth);
    tasks.spawn(async move { shared.check(credentials()).await });
    started.recv().await.unwrap().release().await;
    assert!(tasks.join_next().await.unwrap().unwrap());
    assert_eq!(remaining, 0);
}

#[tokio::test]
async fn retains_permits_when_callers_are_aborted() {
    let (backend, mut started) = BlockingBackend::new();
    let auth = Arc::new(Authenticator::with_backend(backend));
    let mut tasks = JoinSet::new();
    let mut calls = Vec::new();
    for _ in 0..WORKERS {
        let shared = Arc::clone(&auth);
        tasks.spawn(async move { shared.check(credentials()).await });
        calls.push(started.recv().await.unwrap());
    }
    tasks.abort_all();
    while let Some(result) = tasks.join_next().await {
        assert!(result.unwrap_err().is_cancelled());
    }
    let remaining = auth.permits.available_permits();
    let mut overloaded = Box::pin(auth.check(credentials()));
    assert_pending(overloaded.as_mut()).await;
    drop(overloaded);
    for call in calls {
        call.release().await;
    }
    let restored = Arc::clone(&auth.permits)
        .acquire_many_owned(WORKERS.try_into().unwrap())
        .await
        .unwrap();
    drop(restored);
    assert_eq!(remaining, 0);
}

#[test]
fn retains_queued_permits_when_futures_are_dropped_before_worker_start() {
    let runtime = Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(1)
        .build()
        .unwrap();
    runtime.block_on(async {
        let (release, gate) = mpsc::sync_channel(1);
        let (entered, ready) = mpsc::sync_channel(1);
        let blocker = tokio::task::spawn_blocking(move || {
            entered.send(()).unwrap();
            gate.recv_timeout(Duration::from_secs(5)).unwrap();
        });
        ready.recv_timeout(Duration::from_secs(5)).unwrap();
        let (backend, mut started) = BlockingBackend::new();
        let auth = Authenticator::with_backend(backend);
        let mut pending = Vec::new();
        for _ in 0..WORKERS {
            let mut request = Box::pin(auth.check(credentials()));
            assert_pending(request.as_mut()).await;
            pending.push(request);
        }
        drop(pending);
        let remaining = auth.permits.available_permits();
        let mut accepted_fut = Box::pin(auth.check(credentials()));
        assert_pending(accepted_fut.as_mut()).await;
        drop(accepted_fut);
        release.send(()).unwrap();
        blocker.await.unwrap();
        for _ in 0..WORKERS {
            started.recv().await.unwrap().release().await;
        }
        let restored = Arc::clone(&auth.permits)
            .acquire_many_owned(WORKERS.try_into().unwrap())
            .await
            .unwrap();
        drop(restored);
        assert_eq!(remaining, 0);
    });
    runtime.shutdown_timeout(Duration::from_secs(2));
}
