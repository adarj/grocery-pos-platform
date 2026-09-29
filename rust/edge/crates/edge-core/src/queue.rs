use std::fmt;
use std::sync::Arc;

use edge_protocol::{
    AgentUptimeMs, BindingInstanceId, CommandId, CommandKind, CommandTimeoutMs, DeviceId,
    NonterminalCommandState,
};

use crate::ResourceId;

/// Typed, already-recorded handoff. Only Core constructs it; no request ID,
/// freshness deadline, raw JSON, or business decision travels to execution.
pub struct QueuedCommand<P> {
    command_id: CommandId,
    device_id: DeviceId,
    binding_instance_id: BindingInstanceId,
    kind: CommandKind,
    accepted_agent_uptime_ms: AgentUptimeMs,
    timeout_ms: CommandTimeoutMs,
    payload: Arc<P>,
}

impl<P> QueuedCommand<P> {
    pub(crate) fn new(
        state: &NonterminalCommandState,
        timeout_ms: CommandTimeoutMs,
        payload: Arc<P>,
    ) -> Self {
        Self {
            command_id: state.command_id.clone(),
            device_id: state.device_id.clone(),
            binding_instance_id: state.binding_instance_id.clone(),
            kind: state.kind.clone(),
            accepted_agent_uptime_ms: state.accepted_agent_uptime_ms,
            timeout_ms,
            payload,
        }
    }

    pub fn command_id(&self) -> &CommandId {
        &self.command_id
    }

    pub fn device_id(&self) -> &DeviceId {
        &self.device_id
    }

    pub fn binding_instance_id(&self) -> &BindingInstanceId {
        &self.binding_instance_id
    }

    pub fn kind(&self) -> &CommandKind {
        &self.kind
    }

    pub fn accepted_agent_uptime_ms(&self) -> AgentUptimeMs {
        self.accepted_agent_uptime_ms
    }

    pub fn timeout_ms(&self) -> CommandTimeoutMs {
        self.timeout_ms
    }

    pub fn payload(&self) -> &P {
        &self.payload
    }
}

impl<P> fmt::Debug for QueuedCommand<P> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("QueuedCommand")
            .field("command_id", &self.command_id)
            .field("device_id", &self.device_id)
            .field("binding_instance_id", &self.binding_instance_id)
            .field("kind", &self.kind)
            .field("accepted_agent_uptime_ms", &self.accepted_agent_uptime_ms)
            .field("timeout_ms", &self.timeout_ms)
            .field("payload", &"<redacted>")
            .finish()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum QueueReservationError {
    Full,
    Unavailable,
}

/// The only permitted commit error: the command was never made visible.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum QueueCommitError {
    GuaranteedNotEnqueued,
}

/// Future bounded FIFO executor seam. A successful reserve holds exactly one
/// waiting slot; dropping an unused reservation releases it. Before commit,
/// the executor cannot observe the command. Successful commit makes it visible
/// exactly once. An error guarantees no executor ever observed that command.
/// Implementations unable to prove these guarantees cannot implement this port.
pub trait ExecutorQueuePort<P> {
    type Reservation;

    fn reserve(
        &mut self,
        resource: &ResourceId,
    ) -> Result<Self::Reservation, QueueReservationError>;

    /// Core borrows the just-created active record as a witness while calling
    /// commit. Publication may occur during this call because the Core record
    /// already exists; returning an error guarantees publication never occurred.
    fn commit(
        &mut self,
        reservation: Self::Reservation,
        command: QueuedCommand<P>,
        recorded: &NonterminalCommandState,
    ) -> Result<(), QueueCommitError>;
}
