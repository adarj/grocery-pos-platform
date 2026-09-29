use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::text::protocol_text;
use crate::{AgentInstanceId, BindingInstanceId, DeviceId, MAX_SEMANTIC_NAME_BYTES, StateRevision};

protocol_text!(
    /// Configured name of a compiled adapter; not a library path or discovery descriptor.
    AdapterKind, MAX_SEMANTIC_NAME_BYTES
);
protocol_text!(
    /// Published semantic operation, requiring future configuration/adapter/hardware intersection.
    Capability, MAX_SEMANTIC_NAME_BYTES
);
protocol_text!(
    /// Semantic condition such as a namespaced device status, never raw driver text.
    ConditionCode, MAX_SEMANTIC_NAME_BYTES
);

/// Device availability does not decide POS readiness or workflow policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeviceAvailability {
    Disabled,
    Absent,
    Connecting,
    Ready,
    Degraded,
    Faulted,
}

/// Complete public state of one configured logical slot, not a discovery inventory.
/// Core must supply consistent epoch/revision/capability facts; DTOs do not authorize hardware.
/// Response fields may evolve additively; unknown safety enum values still fail.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct DeviceSnapshot {
    pub agent_instance_id: AgentInstanceId,
    pub device_id: DeviceId,
    pub binding_instance_id: Option<BindingInstanceId>,
    pub state_revision: StateRevision,
    pub adapter_kind: AdapterKind,
    pub availability: DeviceAvailability,
    pub conditions: BTreeSet<ConditionCode>,
    pub capabilities: BTreeSet<Capability>,
}
