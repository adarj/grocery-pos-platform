use std::collections::BTreeMap;

use edge_protocol::{
    AgentUptimeMs, CommandKind, CommandPayloadDecodeError, CommandPayloadDecoder, CommandTimeoutMs,
    DEFAULT_EVENT_RECORD_MAX_BYTES, DEFAULT_NON_STREAM_RESPONSE_MAX_BYTES, DeviceSnapshot,
    JsonDecodeError, JsonDecodeLimits, JsonEncodeError, StrictJsonFragment, StrictJsonSchema,
    TypedCommandPayload, decode_command_strict, decode_json_strict, encode_json_bounded,
};
use serde::{Deserialize, Serialize};

fn decode<T: StrictJsonSchema>(body: &[u8]) -> Result<T, JsonDecodeError> {
    decode_json_strict(body, JsonDecodeLimits::COMMAND_REQUEST)
}

fn limits(change: impl FnOnce(&mut JsonDecodeLimits)) -> JsonDecodeLimits {
    let mut limits = JsonDecodeLimits::COMMAND_REQUEST;
    change(&mut limits);
    limits
}

#[derive(Debug, Eq, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct ObservePayload {
    count: u64,
}
impl StrictJsonSchema for ObservePayload {}

#[derive(Debug, Eq, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct SignalPayload {
    level: u64,
    marker: String,
}
impl StrictJsonSchema for SignalPayload {}

#[derive(Debug, Eq, PartialEq)]
enum SyntheticPayload {
    Observe(ObservePayload),
    Signal(SignalPayload),
}
impl TypedCommandPayload for SyntheticPayload {
    fn command_kind(&self) -> &'static str {
        match self {
            Self::Observe(_) => "synthetic.observe",
            Self::Signal(_) => "synthetic.signal",
        }
    }
}

struct SyntheticDecoder;
impl CommandPayloadDecoder for SyntheticDecoder {
    type Payload = SyntheticPayload;

    fn decode_payload(
        kind: &CommandKind,
        payload: StrictJsonFragment<'_>,
    ) -> Result<Self::Payload, CommandPayloadDecodeError> {
        match kind.as_str() {
            "synthetic.observe" => payload
                .decode::<ObservePayload>()
                .map(SyntheticPayload::Observe),
            "synthetic.signal" => payload
                .decode::<SignalPayload>()
                .map(SyntheticPayload::Signal),
            _ => Err(CommandPayloadDecodeError::UnknownKind),
        }
    }
}

// Deliberately buggy compiled dispatch: the payload schema is real, but its
// variant does not match the requested kind.
struct CrossedDecoder;
impl CommandPayloadDecoder for CrossedDecoder {
    type Payload = SyntheticPayload;

    fn decode_payload(
        _kind: &CommandKind,
        payload: StrictJsonFragment<'_>,
    ) -> Result<Self::Payload, CommandPayloadDecodeError> {
        payload
            .decode::<SignalPayload>()
            .map(SyntheticPayload::Signal)
    }
}

fn command_json(request_id: &str, kind: &str, payload: &str) -> String {
    format!(
        r#"{{"request_id":"{request_id}","command_id":"command-a","expected_agent_instance_id":"agent-a","device_id":"lane-a.device","expected_binding_instance_id":"binding-a","not_after_agent_uptime_ms":950113,"kind":"{kind}","timeout_ms":5000,"payload":{payload}}}"#
    )
}

fn decode_command(
    body: &[u8],
) -> Result<edge_protocol::CommandSubmission<SyntheticPayload>, JsonDecodeError> {
    decode_command_strict::<SyntheticDecoder>(body, JsonDecodeLimits::COMMAND_REQUEST)
}

#[test]
fn semantic_payload_rejection_is_distinct_from_structural_schema_failure() {
    struct SemanticDecoder;
    impl CommandPayloadDecoder for SemanticDecoder {
        type Payload = SyntheticPayload;
        fn decode_payload(
            _: &CommandKind,
            payload: StrictJsonFragment<'_>,
        ) -> Result<Self::Payload, CommandPayloadDecodeError> {
            payload.decode::<ObservePayload>()?;
            Err(CommandPayloadDecodeError::SemanticViolation)
        }
    }
    let body = command_json("request-a", "synthetic.observe", r#"{"count":0}"#);
    assert_eq!(
        decode_command_strict::<SemanticDecoder>(
            body.as_bytes(),
            JsonDecodeLimits::COMMAND_REQUEST
        )
        .unwrap_err(),
        JsonDecodeError::PayloadSemanticViolation
    );
    let structural = body.replace(r#""count":0"#, r#""unknown":0"#);
    assert_eq!(
        decode_command_strict::<SemanticDecoder>(
            structural.as_bytes(),
            JsonDecodeLimits::COMMAND_REQUEST
        )
        .unwrap_err(),
        JsonDecodeError::PayloadSchemaViolation
    );
}

#[test]
fn one_bounded_json_document_decodes_and_framing_is_strict() {
    assert_eq!(decode::<u64>(b"7 \n"), Ok(7));
    assert_eq!(
        decode::<u64>(b"").unwrap_err(),
        JsonDecodeError::MalformedJson
    );
    assert_eq!(
        decode::<u64>(b" \n\t ").unwrap_err(),
        JsonDecodeError::MalformedJson
    );
    assert_eq!(
        decode::<u64>(b"{").unwrap_err(),
        JsonDecodeError::MalformedJson
    );
    assert_eq!(
        decode::<u64>(b"7 8").unwrap_err(),
        JsonDecodeError::TrailingData
    );
    assert_eq!(
        decode::<u64>(b"7 garbage").unwrap_err(),
        JsonDecodeError::TrailingData
    );
    assert_eq!(
        decode::<u64>(b"\xff").unwrap_err(),
        JsonDecodeError::InvalidUtf8
    );

    let limit = limits(|it| it.max_input_bytes = 1);
    assert_eq!(decode_json_strict::<u64>(b"7", limit), Ok(7));
    assert_eq!(
        decode_json_strict::<u64>(b"\xff\xff", limit).unwrap_err(),
        JsonDecodeError::InputTooLarge
    );
}

#[test]
fn decoded_duplicate_keys_are_rejected_at_every_level() {
    for body in [
        br#"{"payload":1,"payload":2}"#.as_slice(),
        br#"{"payload":1,"\u0070ayload":2}"#.as_slice(),
        br#"{"outer":{"payload":1,"payload":2}}"#.as_slice(),
        br#"{"outer":[{"deep":{"payload":1,"payload":2}}]}"#.as_slice(),
    ] {
        assert_eq!(
            decode::<BTreeMap<String, u64>>(body).unwrap_err(),
            JsonDecodeError::DuplicateObjectKey
        );
    }
}

#[test]
fn decoded_strings_and_keys_use_utf8_byte_limits() {
    let limit = limits(|it| it.max_string_bytes = 2);
    assert_eq!(
        decode_json_strict::<String>(br#""ab""#, limit),
        Ok("ab".into())
    );
    assert_eq!(
        decode_json_strict::<String>(br#""abc""#, limit).unwrap_err(),
        JsonDecodeError::StringLimitExceeded
    );
    assert_eq!(
        decode_json_strict::<String>(br#""\u0061b""#, limit),
        Ok("ab".into())
    );
    assert_eq!(
        decode_json_strict::<String>(br#""\u0061bc""#, limit).unwrap_err(),
        JsonDecodeError::StringLimitExceeded
    );
    assert_eq!(
        decode_json_strict::<String>("\"é\"".as_bytes(), limit),
        Ok("é".into())
    );
    assert_eq!(
        decode_json_strict::<String>("\"éa\"".as_bytes(), limit).unwrap_err(),
        JsonDecodeError::StringLimitExceeded
    );

    let limit = limits(|it| it.max_object_key_bytes = 2);
    assert!(decode_json_strict::<BTreeMap<String, u64>>(br#"{"ab":1}"#, limit).is_ok());
    assert!(decode_json_strict::<BTreeMap<String, u64>>(br#"{"\u0061b":1}"#, limit).is_ok());
    assert_eq!(
        decode_json_strict::<BTreeMap<String, u64>>(br#"{"\u0061bc":1}"#, limit).unwrap_err(),
        JsonDecodeError::ObjectKeyLimitExceeded
    );
    assert!(decode_json_strict::<BTreeMap<String, u64>>("{\"é\":1}".as_bytes(), limit).is_ok());
    assert_eq!(
        decode_json_strict::<BTreeMap<String, u64>>(br#"{"abc":1}"#, limit).unwrap_err(),
        JsonDecodeError::ObjectKeyLimitExceeded
    );
}

#[test]
fn per_container_and_aggregate_limits_have_exact_boundaries() {
    let array = limits(|it| it.max_array_items = 2);
    assert_eq!(
        decode_json_strict::<Vec<u64>>(b"[1,2]", array),
        Ok(vec![1, 2])
    );
    assert_eq!(
        decode_json_strict::<Vec<u64>>(b"[1,2,3]", array).unwrap_err(),
        JsonDecodeError::ArrayLimitExceeded
    );

    let object = limits(|it| it.max_object_members = 2);
    assert!(decode_json_strict::<BTreeMap<String, u64>>(br#"{"a":1,"b":2}"#, object).is_ok());
    assert_eq!(
        decode_json_strict::<BTreeMap<String, u64>>(br#"{"a":1,"b":2,"c":3}"#, object).unwrap_err(),
        JsonDecodeError::ObjectMemberLimitExceeded
    );

    let values = limits(|it| it.max_total_values = 3);
    assert_eq!(
        decode_json_strict::<Vec<u64>>(b"[1,2]", values),
        Ok(vec![1, 2])
    );
    assert_eq!(
        decode_json_strict::<Vec<u64>>(b"[1,2,3]", values).unwrap_err(),
        JsonDecodeError::ValueLimitExceeded
    );
}

#[test]
fn existing_numeric_newtypes_remain_authoritative() {
    assert_eq!(
        decode::<AgentUptimeMs>(b"18446744073709551615"),
        Ok(AgentUptimeMs::new(u64::MAX))
    );
    for body in [
        b"-1".as_slice(),
        b"1.5".as_slice(),
        b"18446744073709551616".as_slice(),
    ] {
        assert_eq!(
            decode::<AgentUptimeMs>(body).unwrap_err(),
            JsonDecodeError::SchemaViolation
        );
    }
    assert_eq!(
        decode::<CommandTimeoutMs>(b"0").unwrap_err(),
        JsonDecodeError::SchemaViolation
    );
}

#[test]
fn command_envelope_uses_validated_identifier_types() {
    let body = command_json("request-a", "synthetic.observe", r#"{"count":3}"#)
        .replace(r#""command_id":"command-a""#, r#""command_id":"""#);
    assert_eq!(
        decode_command(body.as_bytes()).unwrap_err(),
        JsonDecodeError::SchemaViolation
    );
}

#[test]
fn response_additions_remain_compatible_but_unknown_safety_states_fail() {
    let valid = br#"{"agent_instance_id":"agent-a","device_id":"lane-a.device","binding_instance_id":null,"state_revision":1,"adapter_kind":"synthetic","availability":"ready","conditions":[],"capabilities":[],"future_metadata":7}"#;
    assert!(
        decode::<DeviceSnapshot>(valid)
            .unwrap()
            .binding_instance_id
            .is_none()
    );
    let unknown = br#"{"agent_instance_id":"agent-a","device_id":"lane-a.device","binding_instance_id":null,"state_revision":1,"adapter_kind":"synthetic","availability":"unrecognized","conditions":[],"capabilities":[]}"#;
    assert_eq!(
        decode::<DeviceSnapshot>(unknown).unwrap_err(),
        JsonDecodeError::SchemaViolation
    );
}

#[test]
fn command_dispatch_binds_kind_to_a_strict_typed_payload() {
    let observed = command_json("request-a", "synthetic.observe", r#"{"count":3}"#);
    assert!(matches!(
        decode_command(observed.as_bytes()).unwrap().payload,
        SyntheticPayload::Observe(ObservePayload { count: 3 })
    ));
    let signaled = command_json(
        "request-a",
        "synthetic.signal",
        r#"{"level":3,"marker":"harmless"}"#,
    );
    assert!(matches!(
        decode_command(signaled.as_bytes()).unwrap().payload,
        SyntheticPayload::Signal(SignalPayload { level: 3, .. })
    ));

    let wrong = command_json(
        "request-a",
        "synthetic.observe",
        r#"{"level":3,"marker":"harmless"}"#,
    );
    assert_eq!(
        decode_command(wrong.as_bytes()).unwrap_err(),
        JsonDecodeError::PayloadSchemaViolation
    );
    let unknown = command_json("request-a", "synthetic.unknown", r#"{"count":3}"#);
    assert_eq!(
        decode_command(unknown.as_bytes()).unwrap_err(),
        JsonDecodeError::UnknownCommandKind
    );
    let extra = command_json("request-a", "synthetic.observe", r#"{"count":3,"extra":4}"#);
    assert_eq!(
        decode_command(extra.as_bytes()).unwrap_err(),
        JsonDecodeError::PayloadSchemaViolation
    );
}

#[test]
fn compiled_dispatch_cannot_return_a_mismatched_kind_and_payload() {
    for kind in ["synthetic.observe", "synthetic.unknown"] {
        let body = command_json("request-a", kind, r#"{"level":3,"marker":"harmless"}"#);
        assert_eq!(
            decode_command_strict::<CrossedDecoder>(
                body.as_bytes(),
                JsonDecodeLimits::COMMAND_REQUEST,
            )
            .unwrap_err(),
            JsonDecodeError::PayloadSchemaViolation
        );
    }
}

#[test]
fn command_property_order_and_semantic_json_spelling_do_not_change_identity() {
    let first = command_json(
        "request-a",
        "synthetic.signal",
        r#"{"level":3,"marker":"harmless"}"#,
    );
    let second = r#"{"payload":{"marker":"harm\u006cess","level":3},"timeout_ms":5000,"kind":"synthetic.signal","not_after_agent_uptime_ms":950113,"expected_binding_instance_id":"binding-a","device_id":"lane-a.device","expected_agent_instance_id":"agent-a","command_id":"command-a","request_id":"request-b"}"#;
    let first = decode_command(first.as_bytes()).unwrap();
    let second = decode_command(second.as_bytes()).unwrap();
    assert_eq!(first.semantic_identity(), second.semantic_identity());
    assert_ne!(first.request_id, second.request_id);
}

#[test]
fn command_envelope_and_payload_duplicates_fail_before_dispatch() {
    let extra = command_json("request-a", "synthetic.observe", r#"{"count":3}"#).replace(
        r#""payload":{"count":3}"#,
        r#""extra":1,"payload":{"count":3}"#,
    );
    assert_eq!(
        decode_command(extra.as_bytes()).unwrap_err(),
        JsonDecodeError::SchemaViolation
    );
    for payload in [
        r#"{"count":3,"count":4}"#,
        r#"{"count":3,"\u0063ount":4}"#,
        r#"{"count":3,"nested":{"x":1,"x":2}}"#,
    ] {
        let body = command_json("request-a", "synthetic.observe", payload);
        assert_eq!(
            decode_command(body.as_bytes()).unwrap_err(),
            JsonDecodeError::DuplicateObjectKey
        );
    }
}

#[test]
fn codec_errors_never_echo_hostile_source_material() {
    const SENTINEL: &str = "PRIVATE_SENTINEL";
    let hostile = [
        format!(r#"{{"{SENTINEL}":1,"{SENTINEL}":2}}"#),
        format!(r#""{SENTINEL}""#),
        format!(r#"{{"{SENTINEL}":"#),
        command_json(
            "request-a",
            "synthetic.observe",
            &format!(r#"{{"count":3,"{SENTINEL}":4}}"#),
        ),
    ];
    for (index, body) in hostile.iter().enumerate() {
        let error = if index == 3 {
            decode_command(body.as_bytes()).unwrap_err()
        } else {
            decode_json_strict::<String>(body.as_bytes(), limits(|it| it.max_string_bytes = 3))
                .unwrap_err()
        };
        assert!(!error.to_string().contains(SENTINEL));
        assert!(!format!("{error:?}").contains(SENTINEL));
    }
    let unknown_envelope = command_json("request-a", "synthetic.observe", r#"{"count":3}"#)
        .replace(
            r#""payload":{"count":3}"#,
            &format!(r#""{SENTINEL}":1,"payload":{{"count":3}}"#),
        );
    let wrong_payload = command_json(
        "request-a",
        "synthetic.observe",
        &format!(r#"{{"count":"{SENTINEL}"}}"#),
    );
    let unknown_kind = command_json(
        "request-a",
        &format!("synthetic.{SENTINEL}"),
        r#"{"count":3}"#,
    );
    for body in [unknown_envelope, wrong_payload, unknown_kind] {
        let error = decode_command(body.as_bytes()).unwrap_err();
        assert!(!error.to_string().contains(SENTINEL));
        assert!(!format!("{error:?}").contains(SENTINEL));
    }
}

#[test]
fn bounded_encoding_discards_oversized_partial_documents() {
    assert_eq!(DEFAULT_NON_STREAM_RESPONSE_MAX_BYTES, 256 * 1024);
    assert_eq!(DEFAULT_EVENT_RECORD_MAX_BYTES, 64 * 1024);
    assert_eq!(encode_json_bounded(&"a", 3), Ok(br#""a""#.to_vec()));
    assert_eq!(
        encode_json_bounded(&"a", 2),
        Err(JsonEncodeError::OutputTooLarge)
    );
    let snapshot: DeviceSnapshot = decode(
        br#"{"agent_instance_id":"agent-a","device_id":"lane-a.device","binding_instance_id":null,"state_revision":1,"adapter_kind":"synthetic","availability":"ready","conditions":[],"capabilities":[]}"#,
    ).unwrap();
    let encoded = encode_json_bounded(&snapshot, DEFAULT_NON_STREAM_RESPONSE_MAX_BYTES).unwrap();
    assert!(!encoded.is_empty());
    assert!(encoded.len() < DEFAULT_EVENT_RECORD_MAX_BYTES);
    assert_eq!(
        encode_json_bounded(&snapshot, DEFAULT_EVENT_RECORD_MAX_BYTES),
        Ok(encoded.clone())
    );
    assert!(decode::<DeviceSnapshot>(&encoded).is_ok());
}

#[test]
fn encoder_sanitizes_serialization_failures() {
    struct HostileError;
    impl Serialize for HostileError {
        fn serialize<S: serde::Serializer>(&self, _serializer: S) -> Result<S::Ok, S::Error> {
            Err(serde::ser::Error::custom("PRIVATE_SENTINEL"))
        }
    }
    let error = encode_json_bounded(&HostileError, 20).unwrap_err();
    assert_eq!(error, JsonEncodeError::SerializationFailure);
    assert!(!error.to_string().contains("PRIVATE_SENTINEL"));
    assert!(!format!("{error:?}").contains("PRIVATE_SENTINEL"));
}
