use edge_protocol::{
    AgentInstanceId, AgentUptimeMs, BindingInstanceId, CommandId, CommandTimeoutMs, DeviceId,
    EventCursor, EventSequence, MAX_IDENTIFIER_BYTES, ProtocolMajor, ProtocolVersion, RequestId,
    StateRevision,
};
use serde::{Serialize, de::DeserializeOwned};
use serde_json::json;

fn assert_round_trip<T>(value: T, expected: serde_json::Value)
where
    T: Serialize + DeserializeOwned + std::fmt::Debug + PartialEq,
{
    assert_eq!(serde_json::to_value(&value).unwrap(), expected);
    assert_eq!(serde_json::from_value::<T>(expected).unwrap(), value);
}

#[test]
fn identifiers_are_opaque_nonempty_bounded_strings() {
    // No UUID or logical-device lexical grammar is imposed by these types.
    assert_round_trip(
        AgentInstanceId::new("synthetic agent α").unwrap(),
        json!("synthetic agent α"),
    );
    assert_round_trip(
        BindingInstanceId::new("binding-test").unwrap(),
        json!("binding-test"),
    );
    assert_round_trip(
        CommandId::new("command-test").unwrap(),
        json!("command-test"),
    );
    assert_round_trip(
        RequestId::new("request-test").unwrap(),
        json!("request-test"),
    );
    assert_round_trip(
        DeviceId::new("synthetic logical slot").unwrap(),
        json!("synthetic logical slot"),
    );

    assert!(AgentInstanceId::new("").is_err());
    assert!(BindingInstanceId::new("").is_err());
    assert!(CommandId::new("").is_err());
    assert!(RequestId::new("").is_err());
    assert!(DeviceId::new("").is_err());
    let at_limit = "a".repeat(MAX_IDENTIFIER_BYTES);
    assert!(CommandId::new(at_limit).is_ok());
    let too_long = "é".repeat(MAX_IDENTIFIER_BYTES / 2 + 1);
    assert!(CommandId::new(too_long.clone()).is_err());
    assert!(serde_json::from_value::<CommandId>(json!(too_long)).is_err());
    assert!(serde_json::from_value::<DeviceId>(json!("")).is_err());
    assert!(serde_json::from_value::<RequestId>(json!(7)).is_err());
}

#[test]
fn integer_domains_preserve_exact_values() {
    assert_round_trip(AgentUptimeMs::new(u64::MAX), json!(u64::MAX));
    assert_round_trip(StateRevision::new(7), json!(7));
    assert_round_trip(EventSequence::new(42), json!(42));
    assert_round_trip(EventCursor::new(0), json!(0));
    assert_round_trip(CommandTimeoutMs::new(5000).unwrap(), json!(5000));
    assert!(CommandTimeoutMs::new(0).is_none());
    assert!(serde_json::from_value::<CommandTimeoutMs>(json!(0)).is_err());
    assert!(serde_json::from_value::<AgentUptimeMs>(json!(-1)).is_err());
    assert!(serde_json::from_value::<AgentUptimeMs>(json!(1.5)).is_err());
}

#[test]
fn protocol_major_v1_is_explicit_and_minor_metadata_can_grow() {
    assert_round_trip(ProtocolVersion::V1, json!({"major": 1, "minor": 0}));
    assert_round_trip(
        ProtocolVersion {
            major: ProtocolMajor::V1,
            minor: 9,
        },
        json!({"major": 1, "minor": 9}),
    );
    assert!(serde_json::from_value::<ProtocolVersion>(json!({"major": 2, "minor": 0})).is_err());
}
