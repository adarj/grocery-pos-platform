use serde::{Deserialize, Serialize};

use crate::{
    AgentInstanceId, AgentUptimeMs, BindingInstanceId, CommandState, DeviceId, DeviceObservation,
    DeviceSnapshot, EventCursor, EventSequence, StateRevision,
};

/// Generic event vocabulary only; no NDJSON framing, subscription, or replay machinery.
/// Core supplies atomic snapshots and contiguous per-agent live sequences.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum EdgeEvent {
    #[serde(rename = "snapshot")]
    Snapshot(SnapshotEvent),
    // Box complete state changes to keep the enum compact, without changing wire shape.
    #[serde(rename = "device.state_changed")]
    DeviceStateChanged(Box<DeviceStateChangedEvent>),
    #[serde(rename = "command.state_changed")]
    CommandStateChanged(Box<CommandStateChangedEvent>),
    #[serde(rename = "device.observation")]
    DeviceObservation(Box<DeviceObservationEvent>),
    #[serde(rename = "heartbeat")]
    Heartbeat(HeartbeatEvent),
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceObservationEvent {
    pub agent_instance_id: AgentInstanceId,
    pub sequence: EventSequence,
    pub device_id: DeviceId,
    pub binding_instance_id: BindingInstanceId,
    pub state_revision: StateRevision,
    pub observation: DeviceObservation,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SnapshotEvent {
    pub agent_instance_id: AgentInstanceId,
    pub event_cursor: EventCursor,
    pub agent_uptime_ms: AgentUptimeMs,
    pub devices: Vec<DeviceSnapshot>,
}

/// Complete replacement device snapshot with explicit stream identity/revision metadata.
/// Core must ensure outer metadata matches the contained snapshot.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct DeviceStateChangedEvent {
    pub agent_instance_id: AgentInstanceId,
    pub sequence: EventSequence,
    pub device_id: DeviceId,
    pub binding_instance_id: Option<BindingInstanceId>,
    pub state_revision: StateRevision,
    pub device: DeviceSnapshot,
}

/// The command retains its original binding identity even if that binding is invalidated.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CommandStateChangedEvent {
    pub agent_instance_id: AgentInstanceId,
    pub sequence: EventSequence,
    pub command: CommandState,
}

/// Heartbeats neither require nor consume an event sequence number.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct HeartbeatEvent {
    pub agent_instance_id: AgentInstanceId,
    pub agent_uptime_ms: AgentUptimeMs,
}
