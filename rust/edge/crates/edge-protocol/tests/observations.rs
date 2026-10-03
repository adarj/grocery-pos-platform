use edge_protocol::*;

#[test]
fn barcode_is_opaque_bounded_and_private() {
    for value in ["0", " 049000001234 ", "\0\n\t"] {
        let barcode = BarcodeValue::new(value).unwrap();
        assert_eq!(barcode.as_str(), value);
        assert!(!format!("{barcode:?}").contains(value));
        let raw = wire(&serde_json::to_string(value).unwrap());
        let event: EdgeEvent =
            decode_json_strict(raw.as_bytes(), JsonDecodeLimits::default()).unwrap();
        let encoded = encode_json_bounded(&event, DEFAULT_EVENT_RECORD_MAX_BYTES).unwrap();
        let decoded: EdgeEvent = decode_json_strict(&encoded, JsonDecodeLimits::default()).unwrap();
        assert_eq!(decoded, event);
        if let EdgeEvent::DeviceObservation(e) = decoded {
            let DeviceObservation::ScannerBarcode { barcode } = e.observation;
            assert_eq!(barcode.as_str(), value);
        } else {
            panic!("wrong typed event");
        }
    }
    assert!(BarcodeValue::new("").is_err());
    assert!(BarcodeValue::new("a".repeat(4096)).is_ok());
    assert!(BarcodeValue::new("a".repeat(4097)).is_err());
    assert!(BarcodeValue::new("🦀".repeat(1024)).is_ok());
    assert!(BarcodeValue::new("🦀".repeat(1025)).is_err());
}

fn wire(barcode: &str) -> String {
    format!(
        r#"{{"type":"device.observation","agent_instance_id":"agent","sequence":42,"device_id":"scanner","binding_instance_id":"binding","state_revision":3,"observation":{{"kind":"scanner.barcode","barcode":{barcode}}}}}"#
    )
}

#[test]
fn observation_wire_is_closed_typed_and_bounded() {
    let raw = wire(r#""049000001234""#);
    let event: EdgeEvent = decode_json_strict(raw.as_bytes(), JsonDecodeLimits::default()).unwrap();
    assert!(
        matches!(&event, EdgeEvent::DeviceObservation(e) if e.sequence.get() == 42 && e.state_revision.get() == 3)
    );
    assert!(!format!("{event:?}").contains("049000001234"));
    assert_eq!(encode_json_bounded(&event, 65536).unwrap(), raw.as_bytes());
    for bad in [
        raw.replace("scanner.barcode", "scanner.bytes"),
        wire("null"),
        wire("1"),
        wire(r#""""#),
        raw.replace(r#""barcode":"049000001234""#, ""),
        raw.replace(r#""sequence":42"#, r#""sequence":-1"#),
        raw.replace(
            r#""binding_instance_id":"binding""#,
            r#""binding_instance_id":null"#,
        ),
        raw.replace(r#""barcode":"049000001234""#, r#""barcode":"a","raw":"b""#),
        wire(&format!("\"{}\"", "a".repeat(4097))),
    ] {
        assert!(
            decode_json_strict::<EdgeEvent>(bad.as_bytes(), JsonDecodeLimits::default()).is_err()
        );
    }
    // Worst-case JSON escaping, plus maximum metadata, still fits the event bound.
    let mut worst: EdgeEvent = decode_json_strict(
        wire(&format!("\"{}\"", "\\u0000".repeat(4096))).as_bytes(),
        JsonDecodeLimits::default(),
    )
    .unwrap();
    if let EdgeEvent::DeviceObservation(e) = &mut worst {
        e.agent_instance_id = AgentInstanceId::new("\0".repeat(256)).unwrap();
        e.device_id = DeviceId::new("\0".repeat(256)).unwrap();
        e.binding_instance_id = BindingInstanceId::new("\0".repeat(256)).unwrap();
        e.sequence = EventSequence::new(u64::MAX);
        e.state_revision = StateRevision::new(u64::MAX);
    }
    assert!(encode_json_bounded(&worst, DEFAULT_EVENT_RECORD_MAX_BYTES).is_ok());
    assert_eq!(ProtocolVersion::CURRENT.minor, 1);
}
