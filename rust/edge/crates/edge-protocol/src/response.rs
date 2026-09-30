use crate::{
    AgentInstanceId, AgentUptimeMs, CommandState, DeviceSnapshot, ProtocolError, ProtocolVersion,
    RequestId,
};
use serde::{Deserialize, Serialize};

/// Process/control-plane liveness; it says nothing about peripheral readiness.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct HealthResponse {
    pub agent_instance_id: AgentInstanceId,
    pub protocol_version: ProtocolVersion,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AgentStatusResponse {
    pub agent_instance_id: AgentInstanceId,
    pub protocol_version: ProtocolVersion,
    pub agent_uptime_ms: AgentUptimeMs,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct DeviceListResponse {
    pub agent_instance_id: AgentInstanceId,
    pub devices: Vec<DeviceSnapshot>,
}

/// Request correlation is transport identity, separate from the retained command.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CommandResponse {
    pub request_id: RequestId,
    pub command: CommandState,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProtocolErrorResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<RequestId>,
    pub error: ProtocolError,
}
