use super::Credentials;

#[test]
fn rejects_line_injection_when_credentials_cross_boundary() {
    for invalid in [b"".as_slice(), b"a\0b", b"a\rb", b"a\nb", &[0xff]] {
        assert!(Credentials::parse(b"chen", invalid).is_err());
        assert!(Credentials::parse(invalid, b"test").is_err());
    }
}

#[test]
fn redacts_password_when_formatted_for_diagnostics() {
    let credentials = Credentials::parse(b"chen", b"synthetic-secret").unwrap();
    assert_eq!(format!("{credentials:?}"), "Credentials([REDACTED])");
}
