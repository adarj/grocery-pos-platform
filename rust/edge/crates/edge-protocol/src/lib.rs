#![forbid(unsafe_code)]

//! Typed values and a strict JSON codec for Edge Protocol v1; no server, Core,
//! or device I/O.
//!
//! Untrusted bytes are size-checked before parsing, then structurally preflighted
//! and decoded into typed values. HTTP framing and Core admission are later work.
//!
//! Initial value ceilings are 256 UTF-8 bytes for opaque identifiers and semantic
//! names/codes, and 1024 bytes for safe error messages. They make these values
//! bounded without a UUID or device-ID lexical grammar. The body-size ceiling is
//! checked before parsing; structural decoded-string/container bounds are checked
//! during the streaming preflight; these type-specific ceilings are checked on
//! typed deserialization. JSON unescaping may allocate before type validation,
//! within the prior bounded body. These are initial implementation choices,
//! not immutable M8.1 protocol constants.

mod codec;
mod command;
mod device;
mod error;
mod event;
mod ids;
mod numbers;
mod response;
mod text;
mod version;

pub use codec::{
    CommandPayloadDecodeError, CommandPayloadDecoder, DEFAULT_EVENT_RECORD_MAX_BYTES,
    DEFAULT_NON_STREAM_RESPONSE_MAX_BYTES, JsonDecodeError, JsonDecodeLimits, JsonEncodeError,
    StrictJsonFragment, StrictJsonSchema, TypedCommandPayload, decode_command_strict,
    decode_json_strict, encode_json_bounded,
};
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

pub use response::{
    AgentStatusResponse, CommandResponse, DeviceListResponse, HealthResponse, ProtocolErrorResponse,
};
