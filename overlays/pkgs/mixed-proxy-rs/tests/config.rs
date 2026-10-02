use super::{Config, PortRange};

#[test]
fn accepts_native_schema_when_auth_transport_is_absent() {
    let json = r#"{"listen":"127.0.0.1:0","tls":{"certFile":"cert","keyFile":"key"},"udp":{"publicAddress":"127.0.0.1","portRange":{"from":20000,"to":20127}}}"#;
    let parsed = serde_json::from_str::<Config>(json);
    assert!(parsed.is_ok());
}

#[test]
fn rejects_legacy_auth_when_native_schema_is_used() {
    let mut fixture: serde_json::Value = serde_json::from_str(include_str!("config.json")).unwrap();
    fixture["auth"] = serde_json::json!({"url":"http://127.0.0.1:19090/auth","timeoutSeconds":12});
    let parsed = serde_json::from_value::<Config>(fixture);
    assert!(parsed.is_err());
}

#[test]
fn parses_frozen_schema_when_all_fields_are_typed() {
    let config: Config = serde_json::from_str(include_str!("config.json")).unwrap();
    assert_eq!(config.listen.port(), 8443);
    assert_eq!(config.udp.port_range.ports().count(), 128);
}

#[test]
fn refuses_unknown_fields_when_nested_configuration_is_extended() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!("config.json")).unwrap();
    for path in [vec![], vec!["tls"], vec!["udp"], vec!["udp", "portRange"]] {
        let mut config = fixture.clone();
        let mut object = &mut config;
        for key in path {
            object = object.get_mut(key).unwrap();
        }
        object
            .as_object_mut()
            .unwrap()
            .insert("extra".to_owned(), serde_json::Value::Bool(true));
        assert!(serde_json::from_value::<Config>(config).is_err());
    }
}

#[test]
fn rejects_invalid_ranges_when_deserializing() {
    // Given invalid numeric range boundaries.
    for json in [
        r#"{"from":0,"to":127}"#,
        r#"{"from":20097,"to":20000}"#,
        r#"{"from":20000,"to":65536}"#,
        r#"{"from":"20000","to":20127}"#,
        r#"{"from":20000,"to":20127,"extra":1}"#,
    ] {
        // When parsing the range.
        let parsed = serde_json::from_str::<PortRange>(json);
        // Then it cannot cross the configuration boundary.
        assert!(parsed.is_err(), "accepted {json}");
    }
}
