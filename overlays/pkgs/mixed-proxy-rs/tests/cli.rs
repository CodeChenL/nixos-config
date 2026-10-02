use serde::Deserialize;
use std::{process::Stdio, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::TcpStream,
    process::Command,
    time::timeout,
};

#[test]
fn reports_version_when_version_flag_is_used() {
    let result = std::process::Command::new(env!("CARGO_BIN_EXE_mixed-proxy"))
        .arg("--version")
        .output()
        .unwrap();
    assert!(result.status.success());
    assert_eq!(result.stdout, b"mixed-proxy 0.1.0\n");
}

#[test]
fn fails_startup_when_configuration_is_invalid() {
    let directory = tempfile::tempdir().unwrap();
    let config = directory.path().join("invalid.json");
    std::fs::write(&config, b"{\"listen\":\"127.0.0.1:0\",\"unexpected\":1}").unwrap();
    let result = std::process::Command::new(env!("CARGO_BIN_EXE_mixed-proxy"))
        .arg("--config")
        .arg(config)
        .output()
        .unwrap();
    assert!(!result.status.success());
    assert!(result.stdout.is_empty());
}

#[test]
fn rejects_legacy_auth_when_configuration_would_otherwise_be_valid() {
    let directory = tempfile::tempdir().unwrap();
    let config = directory.path().join("legacy.json");
    let mut fixture: serde_json::Value = serde_json::from_str(include_str!("config.json")).unwrap();
    fixture["auth"] = serde_json::json!({"url":"http://127.0.0.1:19090/auth","timeoutSeconds":12});
    std::fs::write(&config, serde_json::to_vec(&fixture).unwrap()).unwrap();
    let result = std::process::Command::new(env!("CARGO_BIN_EXE_mixed-proxy"))
        .arg("--config")
        .arg(config)
        .output()
        .unwrap();
    assert!(!result.status.success());
    assert!(result.stdout.is_empty());
}

#[derive(Deserialize)]
struct Startup {
    fields: Fields,
}
#[derive(Deserialize)]
struct Fields {
    listen: std::net::SocketAddr,
}

#[tokio::test]
async fn stops_connections_when_binary_receives_sigterm() {
    let directory = tempfile::tempdir().unwrap();
    let certificate = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()]).unwrap();
    let cert = directory.path().join("cert.pem");
    let key = directory.path().join("key.pem");
    let config = directory.path().join("config.json");
    std::fs::write(&cert, certificate.cert.pem()).unwrap();
    std::fs::write(&key, certificate.signing_key.serialize_pem()).unwrap();
    std::fs::write(&config, format!(r#"{{"listen":"127.0.0.1:0","tls":{{"certFile":"{}","keyFile":"{}"}},"udp":{{"publicAddress":"47.254.74.103","portRange":{{"from":20000,"to":20127}}}}}}"#, cert.display(), key.display())).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_mixed-proxy"))
        .arg("--config")
        .arg(config)
        .env("HOME", directory.path())
        .kill_on_drop(true)
        .stderr(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut lines = BufReader::new(child.stderr.take().unwrap()).lines();
    let ready = timeout(Duration::from_secs(2), lines.next_line())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let startup: Startup = serde_json::from_str(&ready).unwrap();
    let mut stream = TcpStream::connect(startup.fields.listen).await.unwrap();
    stream.write_all(&[5, 1, 0]).await.unwrap();
    let mut method = [0; 2];
    stream.read_exact(&mut method).await.unwrap();
    assert_eq!(method, [5, 255]);
    let mut pending = TcpStream::connect(startup.fields.listen).await.unwrap();
    pending.write_all(&[5, 1, 2]).await.unwrap();
    pending.read_exact(&mut method).await.unwrap();
    assert_eq!(method, [5, 2]);
    let process_id = child.id().unwrap().to_string();
    let signal = Command::new("bash")
        .args(["-c", "kill -TERM \"$1\"", "kill", &process_id])
        .status()
        .await
        .unwrap();
    assert!(signal.success());
    assert!(
        timeout(Duration::from_secs(2), child.wait())
            .await
            .unwrap()
            .unwrap()
            .success()
    );
    assert_eq!(pending.read(&mut method).await.unwrap(), 0);
}
