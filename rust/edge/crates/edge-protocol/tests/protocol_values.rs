use std::collections::BTreeSet;

use edge_protocol::*;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};

fn assert_round_trip<T>(value: T, expected: Value)
where
    T: Serialize + DeserializeOwned + std::fmt::Debug + PartialEq,
{
    assert_eq!(serde_json::to_value(&value).unwrap(), expected);
    assert_eq!(serde_json::from_value::<T>(expected).unwrap(), value);
}

fn device() -> DeviceSnapshot {
    DeviceSnapshot {
        agent_instance_id: AgentInstanceId::new("agent-test").unwrap(),
        device_id: DeviceId::new("lane-test.device").unwrap(),
        binding_instance_id: Some(BindingInstanceId::new("binding-test").unwrap()),
        state_revision: StateRevision::new(7),
        adapter_kind: AdapterKind::new("synthetic-adapter").unwrap(),
        availability: DeviceAvailability::Degraded,
        conditions: BTreeSet::from([ConditionCode::new("synthetic.unavailable").unwrap()]),
        capabilities: BTreeSet::from([
            Capability::new("synthetic.signal").unwrap(),
            Capability::new("synthetic.observe").unwrap(),
            Capability::new("synthetic.observe").unwrap(),
        ]),
    }
}

fn device_json() -> Value {
    json!({
        "agent_instance_id": "agent-test",
        "device_id": "lane-test.device",
        "binding_instance_id": "binding-test",
        "state_revision": 7,
        "adapter_kind": "synthetic-adapter",
        "availability": "degraded",
        "conditions": ["synthetic.unavailable"],
        "capabilities": ["synthetic.observe", "synthetic.signal"]
    })
}

#[test]
fn safety_enums_have_exact_spellings_and_reject_unknown_values() {
    for (value, spelling) in [
        (DeviceAvailability::Disabled, "disabled"),
        (DeviceAvailability::Absent, "absent"),
        (DeviceAvailability::Connecting, "connecting"),
        (DeviceAvailability::Ready, "ready"),
        (DeviceAvailability::Degraded, "degraded"),
        (DeviceAvailability::Faulted, "faulted"),
    ] {
        assert_round_trip(value, json!(spelling));
    }
    for (value, spelling) in [
        (TerminalOutcome::Succeeded, "succeeded"),
        (TerminalOutcome::Rejected, "rejected"),
        (TerminalOutcome::Failed, "failed"),
        (TerminalOutcome::Unknown, "unknown"),
    ] {
        assert_round_trip(value, json!(spelling));
    }
    for (value, spelling) in [
        (EffectEvidence::None, "none"),
        (EffectEvidence::Possible, "possible"),
        (EffectEvidence::Confirmed, "confirmed"),
    ] {
        assert_round_trip(value, json!(spelling));
    }
    assert!(serde_json::from_value::<DeviceAvailability>(json!("future-state")).is_err());
    assert!(serde_json::from_value::<TerminalOutcome>(json!("future-outcome")).is_err());
    assert!(serde_json::from_value::<EffectEvidence>(json!("future-evidence")).is_err());
}

#[test]
fn device_snapshots_use_semantic_fields_and_nullable_bindings() {
    assert_round_trip(device(), device_json());
    let mut absent = device();
    absent.binding_instance_id = None;
    absent.availability = DeviceAvailability::Absent;
    absent.conditions.clear();
    absent.capabilities.clear();
    let mut expected = device_json();
    expected["binding_instance_id"] = Value::Null;
    expected["availability"] = json!("absent");
    expected["conditions"] = json!([]);
    expected["capabilities"] = json!([]);
    assert_round_trip(absent, expected);
}

#[test]
fn responses_allow_additive_fields_without_accepting_unknown_safety_enums() {
    let mut response = device_json();
    response["future_metadata"] = json!("synthetic");
    assert_eq!(
        serde_json::from_value::<DeviceSnapshot>(response.clone()).unwrap(),
        device()
    );
    response["availability"] = json!("future-state");
    assert!(serde_json::from_value::<DeviceSnapshot>(response).is_err());
}

#[test]
fn semantic_names_and_safe_error_text_are_nonempty_and_bounded() {
    assert!(AdapterKind::new("").is_err());
    assert!(Capability::new("").is_err());
    assert!(ConditionCode::new("").is_err());
    assert!(CommandKind::new("").is_err());
    assert!(ErrorCode::new("").is_err());
    assert!(CommandKind::new("x".repeat(MAX_SEMANTIC_NAME_BYTES)).is_ok());
    assert!(Capability::new("x".repeat(MAX_SEMANTIC_NAME_BYTES + 1)).is_err());
    assert!(serde_json::from_value::<CommandKind>(json!("")).is_err());
    assert!(SafeErrorMessage::new("").is_err());
    assert!(SafeErrorMessage::new("x".repeat(MAX_ERROR_MESSAGE_BYTES + 1)).is_err());
    assert_round_trip(
        ProtocolError {
            code: ErrorCode::new("synthetic_failure").unwrap(),
            message: Some(SafeErrorMessage::new("Synthetic operation failed.").unwrap()),
        },
        json!({"code":"synthetic_failure", "message":"Synthetic operation failed."}),
    );
    assert_round_trip(
        ProtocolError {
            code: ErrorCode::new("synthetic_failure").unwrap(),
            message: None,
        },
        json!({"code":"synthetic_failure"}),
    );
}

// Private synthetic schema only; this is not an executable device command contract.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct SyntheticPayload {
    level: u16,
    marker: String,
}

fn submission() -> CommandSubmission<SyntheticPayload> {
    CommandSubmission {
        request_id: RequestId::new("request-test").unwrap(),
        command_id: CommandId::new("command-test").unwrap(),
        expected_agent_instance_id: AgentInstanceId::new("agent-test").unwrap(),
        device_id: DeviceId::new("lane-test.device").unwrap(),
        expected_binding_instance_id: BindingInstanceId::new("binding-test").unwrap(),
        not_after_agent_uptime_ms: AgentUptimeMs::new(950113),
        kind: CommandKind::new("synthetic.signal").unwrap(),
        timeout_ms: CommandTimeoutMs::new(5000).unwrap(),
        payload: SyntheticPayload {
            level: 3,
            marker: "harmless".into(),
        },
    }
}

#[test]
fn generic_command_envelope_has_exact_fields_and_a_typed_payload() {
    assert_round_trip(
        submission(),
        json!({
            "request_id":"request-test",
            "command_id":"command-test",
            "expected_agent_instance_id":"agent-test",
            "device_id":"lane-test.device",
            "expected_binding_instance_id":"binding-test",
            "not_after_agent_uptime_ms":950113,
            "kind":"synthetic.signal",
            "timeout_ms":5000,
            "payload":{"level":3,"marker":"harmless"}
        }),
    );
}

#[test]
fn request_envelope_and_typed_test_payload_reject_unknown_fields() {
    let mut envelope = serde_json::to_value(submission()).unwrap();
    envelope["effect_class"] = json!("caller-choice");
    assert!(serde_json::from_value::<CommandSubmission<SyntheticPayload>>(envelope).is_err());
    let mut payload = serde_json::to_value(submission()).unwrap();
    payload["payload"]["unknown"] = json!(true);
    assert!(serde_json::from_value::<CommandSubmission<SyntheticPayload>>(payload).is_err());
}

#[test]
fn command_diagnostics_do_not_echo_typed_payloads() {
    let command = submission();
    let command_debug = format!("{command:?}");
    let identity_debug = format!("{:?}", command.semantic_identity());
    assert!(!command_debug.contains(&command.payload.marker));
    assert!(!identity_debug.contains(&command.payload.marker));
    assert!(command_debug.contains("command-test"));
    assert!(identity_debug.contains("lane-test.device"));
}

#[test]
fn semantic_identity_excludes_request_attempt_cache_key_and_agent_precondition() {
    let original = submission();
    let mut retry = original.clone();
    retry.request_id = RequestId::new("request-retry").unwrap();
    assert_eq!(original.semantic_identity(), retry.semantic_identity());
    // Core must check the agent precondition before cache lookup; this view is not admission.
    retry.expected_agent_instance_id = AgentInstanceId::new("other-agent").unwrap();
    retry.command_id = CommandId::new("other-cache-key").unwrap();
    assert_eq!(original.semantic_identity(), retry.semantic_identity());
}

#[test]
fn every_semantic_command_field_participates_in_identity() {
    let original = submission();
    let mut changes = Vec::new();
    let mut changed = original.clone();
    changed.device_id = DeviceId::new("other-device").unwrap();
    changes.push(("device", changed));
    let mut changed = original.clone();
    changed.expected_binding_instance_id = BindingInstanceId::new("other-binding").unwrap();
    changes.push(("binding", changed));
    let mut changed = original.clone();
    changed.not_after_agent_uptime_ms = AgentUptimeMs::new(950114);
    changes.push(("freshness", changed));
    let mut changed = original.clone();
    changed.kind = CommandKind::new("synthetic.observe").unwrap();
    changes.push(("kind", changed));
    let mut changed = original.clone();
    changed.timeout_ms = CommandTimeoutMs::new(5001).unwrap();
    changes.push(("timeout", changed));
    let mut changed = original.clone();
    changed.payload.level = 4;
    changes.push(("payload", changed));
    for (field, changed) in changes {
        assert_ne!(
            original.semantic_identity(),
            changed.semantic_identity(),
            "{field}"
        );
    }
}

#[test]
fn typed_identity_is_independent_of_json_property_order() {
    let original = submission();
    let wire = serde_json::to_string(&original).unwrap();
    let reordered = wire.replace(
        r#""payload":{"level":3,"marker":"harmless"}"#,
        r#""payload":{"marker":"harm\u006cess","level":3}"#,
    );
    assert_ne!(wire, reordered);
    let decoded: CommandSubmission<SyntheticPayload> = serde_json::from_str(&reordered).unwrap();
    assert_eq!(original.semantic_identity(), decoded.semantic_identity());
}

fn pending() -> NonterminalCommandState {
    NonterminalCommandState {
        agent_instance_id: AgentInstanceId::new("agent-test").unwrap(),
        command_id: CommandId::new("command-test").unwrap(),
        device_id: DeviceId::new("lane-test.device").unwrap(),
        binding_instance_id: BindingInstanceId::new("binding-test").unwrap(),
        kind: CommandKind::new("synthetic.signal").unwrap(),
        accepted_agent_uptime_ms: AgentUptimeMs::new(945113),
    }
}

fn terminal() -> CommandState {
    CommandState::Terminal(TerminalCommandState {
        agent_instance_id: AgentInstanceId::new("agent-test").unwrap(),
        command_id: CommandId::new("command-test").unwrap(),
        device_id: DeviceId::new("lane-test.device").unwrap(),
        binding_instance_id: BindingInstanceId::new("binding-test").unwrap(),
        kind: CommandKind::new("synthetic.signal").unwrap(),
        accepted_agent_uptime_ms: AgentUptimeMs::new(945113),
        outcome: TerminalOutcome::Unknown,
        effect_evidence: EffectEvidence::Possible,
        error: Some(ProtocolError {
            code: ErrorCode::new("synthetic_timeout").unwrap(),
            message: None,
        }),
        terminal_agent_uptime_ms: AgentUptimeMs::new(950113),
    })
}

fn terminal_json() -> Value {
    json!({
        "agent_instance_id":"agent-test", "command_id":"command-test",
        "device_id":"lane-test.device", "binding_instance_id":"binding-test",
        "kind":"synthetic.signal", "phase":"terminal", "outcome":"unknown",
        "effect_evidence":"possible", "error":{"code":"synthetic_timeout"},
        "accepted_agent_uptime_ms":945113, "terminal_agent_uptime_ms":950113
    })
}

#[test]
fn lifecycle_keeps_terminal_fields_out_of_nonterminal_states() {
    for (state, phase) in [
        (CommandState::Accepted(pending()), "accepted"),
        (CommandState::Executing(pending()), "executing"),
    ] {
        let expected = json!({
            "agent_instance_id":"agent-test", "command_id":"command-test",
            "device_id":"lane-test.device", "binding_instance_id":"binding-test",
            "kind":"synthetic.signal", "phase":phase,
            "accepted_agent_uptime_ms":945113
        });
        assert!(expected.get("outcome").is_none());
        assert!(expected.get("effect_evidence").is_none());
        assert!(expected.get("terminal_agent_uptime_ms").is_none());
        assert_round_trip(state, expected);
    }
    assert_round_trip(terminal(), terminal_json());
    let mut incomplete = terminal_json();
    incomplete
        .as_object_mut()
        .unwrap()
        .remove("effect_evidence");
    assert!(serde_json::from_value::<CommandState>(incomplete).is_err());
    let mut unknown = terminal_json();
    unknown["phase"] = json!("future-phase");
    assert!(serde_json::from_value::<CommandState>(unknown).is_err());
}

#[test]
fn snapshot_and_state_events_preserve_separate_cursor_revision_and_sequence_fields() {
    assert_round_trip(
        EdgeEvent::Snapshot(SnapshotEvent {
            agent_instance_id: AgentInstanceId::new("agent-test").unwrap(),
            event_cursor: EventCursor::new(41),
            agent_uptime_ms: AgentUptimeMs::new(945100),
            devices: vec![device()],
        }),
        json!({"type":"snapshot", "agent_instance_id":"agent-test", "event_cursor":41, "agent_uptime_ms":945100, "devices":[device_json()]}),
    );
    assert_round_trip(
        EdgeEvent::DeviceStateChanged(Box::new(DeviceStateChangedEvent {
            agent_instance_id: AgentInstanceId::new("agent-test").unwrap(),
            sequence: EventSequence::new(42),
            device_id: DeviceId::new("lane-test.device").unwrap(),
            binding_instance_id: Some(BindingInstanceId::new("binding-test").unwrap()),
            state_revision: StateRevision::new(7),
            device: device(),
        })),
        json!({"type":"device.state_changed", "agent_instance_id":"agent-test", "sequence":42, "device_id":"lane-test.device", "binding_instance_id":"binding-test", "state_revision":7, "device":device_json()}),
    );
    assert_round_trip(
        EdgeEvent::CommandStateChanged(Box::new(CommandStateChangedEvent {
            agent_instance_id: AgentInstanceId::new("agent-test").unwrap(),
            sequence: EventSequence::new(43),
            command: terminal(),
        })),
        json!({"type":"command.state_changed", "agent_instance_id":"agent-test", "sequence":43, "command":terminal_json()}),
    );
}

#[test]
fn heartbeat_has_no_event_sequence() {
    assert_round_trip(
        EdgeEvent::Heartbeat(HeartbeatEvent {
            agent_instance_id: AgentInstanceId::new("agent-test").unwrap(),
            agent_uptime_ms: AgentUptimeMs::new(955100),
        }),
        json!({"type":"heartbeat", "agent_instance_id":"agent-test", "agent_uptime_ms":955100}),
    );
    assert!(serde_json::from_value::<EdgeEvent>(json!({"type":"future-event"})).is_err());
}
