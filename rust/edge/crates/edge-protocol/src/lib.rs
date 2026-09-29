#![forbid(unsafe_code)]

//! Typed values for Edge Protocol v1; no server, codec, Core, or device I/O.
//!
//! Serde models field names and basic value invariants. It is not the strict
//! untrusted-JSON boundary: duplicate keys, allocation/depth/collection budgets,
//! framing, and command-specific dispatch remain M8.2.2 responsibilities.
//!
//! Initial value ceilings are 256 UTF-8 bytes for opaque identifiers and semantic
//! names/codes, and 1024 bytes for safe error messages. They make these values
//! bounded without a UUID or device-ID lexical grammar; codec qualification must
//! enforce the ceilings before allocation. They are initial implementation
//! choices, not new immutable M8.1 protocol constants or runtime resource policy.

mod command;
mod device;
mod error;
mod event;
mod ids;
mod numbers;
mod text;
mod version;

pub use command::{
    CommandKind, CommandState, CommandSubmission, EffectEvidence, NonterminalCommandState,
    SemanticCommandIdentity, TerminalCommandState, TerminalOutcome,
};
pub use device::{AdapterKind, Capability, ConditionCode, DeviceAvailability, DeviceSnapshot};
pub use error::{ErrorCode, MAX_ERROR_MESSAGE_BYTES, ProtocolError, SafeErrorMessage};
pub use event::{
    CommandStateChangedEvent, DeviceStateChangedEvent, EdgeEvent, HeartbeatEvent, SnapshotEvent,
};
pub use ids::{
    AgentInstanceId, BindingInstanceId, CommandId, DeviceId, MAX_IDENTIFIER_BYTES, RequestId,
};
pub use numbers::{AgentUptimeMs, CommandTimeoutMs, EventCursor, EventSequence, StateRevision};
pub use text::{MAX_SEMANTIC_NAME_BYTES, TextError};
pub use version::{ProtocolMajor, ProtocolVersion, UnsupportedProtocolMajor};
