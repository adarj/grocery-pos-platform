use std::fmt;

use serde::{Deserialize, Serialize};

use crate::text::protocol_text;
use crate::{
    AgentInstanceId, AgentUptimeMs, BindingInstanceId, CommandId, CommandTimeoutMs, DeviceId,
    MAX_SEMANTIC_NAME_BYTES, ProtocolError, RequestId,
};

protocol_text!(
    /// Semantic command name, not permission to run arbitrary bytes or vendor operations.
    /// Future dispatch must recognize a compiled typed schema and enforce capability allowlisting.
    /// Generic Edge Protocol v1 excludes payment execution.
    CommandKind, MAX_SEMANTIC_NAME_BYTES
);

/// Request DTO with unknown envelope fields rejected and a generic typed payload.
/// This is not the final Core semantic command: `kind` and `P` are independent here.
/// The strict codec binds a recognized kind to its compiled payload schema before
/// returning a wire command for future Core use. This generic DTO alone does
/// not perform kind/payload dispatch or bounded untrusted-JSON decoding.
/// Debug diagnostics redact payload content; callers must not log it separately.
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommandSubmission<P> {
    pub request_id: RequestId,
    pub command_id: CommandId,
    pub expected_agent_instance_id: AgentInstanceId,
    pub device_id: DeviceId,
    pub expected_binding_instance_id: BindingInstanceId,
    pub not_after_agent_uptime_ms: AgentUptimeMs,
    pub kind: CommandKind,
    pub timeout_ms: CommandTimeoutMs,
    pub payload: P,
}

impl<P> fmt::Debug for CommandSubmission<P> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CommandSubmission")
            .field("request_id", &self.request_id)
            .field("command_id", &self.command_id)
            .field(
                "expected_agent_instance_id",
                &self.expected_agent_instance_id,
            )
            .field("device_id", &self.device_id)
            .field(
                "expected_binding_instance_id",
                &self.expected_binding_instance_id,
            )
            .field("not_after_agent_uptime_ms", &self.not_after_agent_uptime_ms)
            .field("kind", &self.kind)
            .field("timeout_ms", &self.timeout_ms)
            .field("payload", &"<redacted>")
            .finish()
    }
}

impl<P> CommandSubmission<P> {
    /// Compare typed semantics while identity is retained. This view is neither
    /// admission nor a compact fingerprint. Core checks the agent epoch before
    /// command-ID lookup. A retry preserves this identity and changes request ID;
    /// a new semantic attempt needs a fresh unpredictable command ID.
    pub fn semantic_identity(&self) -> SemanticCommandIdentity<'_, P> {
        SemanticCommandIdentity {
            device_id: &self.device_id,
            expected_binding_instance_id: &self.expected_binding_instance_id,
            not_after_agent_uptime_ms: self.not_after_agent_uptime_ms,
            kind: &self.kind,
            timeout_ms: self.timeout_ms,
            payload: &self.payload,
        }
    }
}

/// Borrowed typed equality projection, independent of JSON ordering and request attempts.
/// Payload equality must express the compiled command's semantics, not arbitrary JSON bytes.
#[derive(Eq, PartialEq)]
pub struct SemanticCommandIdentity<'a, P> {
    pub device_id: &'a DeviceId,
    pub expected_binding_instance_id: &'a BindingInstanceId,
    pub not_after_agent_uptime_ms: AgentUptimeMs,
    pub kind: &'a CommandKind,
    pub timeout_ms: CommandTimeoutMs,
    pub payload: &'a P,
}

impl<P> fmt::Debug for SemanticCommandIdentity<'_, P> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SemanticCommandIdentity")
            .field("device_id", &self.device_id)
            .field(
                "expected_binding_instance_id",
                &self.expected_binding_instance_id,
            )
            .field("not_after_agent_uptime_ms", &self.not_after_agent_uptime_ms)
            .field("kind", &self.kind)
            .field("timeout_ms", &self.timeout_ms)
            .field("payload", &"<redacted>")
            .finish()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TerminalOutcome {
    /// Command-specific success criterion observed.
    Succeeded,
    /// Adapter/device refused before the requested effect began.
    Rejected,
    /// Known failure to achieve the success criterion; may still involve partial effects.
    Failed,
    /// Physical effect may or may not have occurred; never silently convert to failed/succeeded.
    Unknown,
}

/// Protocol-visible evidence, distinct from future internal effect classes and trackers.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EffectEvidence {
    /// The requested physical effect did not begin.
    None,
    /// Some or all of the requested effect may have occurred.
    Possible,
    /// Command-specific success criterion observed.
    Confirmed,
}

/// Public lifecycle only: no cache, queue, retention, execution, or business retry policy.
/// Terminal-only fields cannot be attached to accepted/executing values.
/// ```compile_fail
/// use edge_protocol::{CommandState, TerminalCommandState};
/// fn invalid(terminal: TerminalCommandState) -> CommandState {
///     CommandState::Accepted(terminal)
/// }
/// ```
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "phase", rename_all = "snake_case")]
pub enum CommandState {
    Accepted(NonterminalCommandState),
    Executing(NonterminalCommandState),
    Terminal(TerminalCommandState),
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct NonterminalCommandState {
    pub agent_instance_id: AgentInstanceId,
    pub command_id: CommandId,
    pub device_id: DeviceId,
    pub binding_instance_id: BindingInstanceId,
    pub kind: CommandKind,
    pub accepted_agent_uptime_ms: AgentUptimeMs,
}

/// Safe public terminal state without full payload, private fingerprint, or cache metadata.
/// Valid outcome/evidence pairs and timing consistency require command-specific Core validation.
/// Core owns terminal immutability; this DTO is not a lifecycle transition engine.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct TerminalCommandState {
    pub agent_instance_id: AgentInstanceId,
    pub command_id: CommandId,
    pub device_id: DeviceId,
    pub binding_instance_id: BindingInstanceId,
    pub kind: CommandKind,
    pub accepted_agent_uptime_ms: AgentUptimeMs,
    pub outcome: TerminalOutcome,
    pub effect_evidence: EffectEvidence,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ProtocolError>,
    pub terminal_agent_uptime_ms: AgentUptimeMs,
}
