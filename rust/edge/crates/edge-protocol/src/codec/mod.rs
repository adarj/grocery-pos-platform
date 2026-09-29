//! Bounded structural JSON decoding, typed command dispatch, and bounded encoding.

mod decode;
mod encode;

use std::collections::BTreeMap;
use std::fmt;

use serde::de::DeserializeOwned;
use serde_json::value::RawValue;

use crate::CommandKind;

pub use decode::{decode_command_strict, decode_json_strict};
pub use encode::encode_json_bounded;

/// Opt-in fixed schema for the generic strict decoder. Raw JSON trees and the
/// independently generic CommandSubmission are intentionally not opted in;
/// command requests use the kind-dispatching entry point instead. Request
/// implementations must reject unknown fields in every nested request struct;
/// this marker cannot infer Serde field policy. Response implementations may
/// remain tolerant of additive fields.
pub trait StrictJsonSchema: DeserializeOwned {}

impl StrictJsonSchema for () {}
impl StrictJsonSchema for bool {}
impl StrictJsonSchema for i64 {}
impl StrictJsonSchema for u64 {}
impl StrictJsonSchema for String {}
impl<T: StrictJsonSchema> StrictJsonSchema for Option<T> {}
impl<T: StrictJsonSchema> StrictJsonSchema for Vec<T> {}
impl<T: StrictJsonSchema> StrictJsonSchema for BTreeMap<String, T> {}
impl StrictJsonSchema for crate::AgentUptimeMs {}
impl StrictJsonSchema for crate::CommandTimeoutMs {}
impl StrictJsonSchema for crate::ProtocolVersion {}
impl StrictJsonSchema for crate::DeviceSnapshot {}
impl StrictJsonSchema for crate::CommandState {}
impl StrictJsonSchema for crate::EdgeEvent {}
impl StrictJsonSchema for crate::ProtocolError {}

/// Initial M8 command-request defaults, subject to implementation qualification.
/// The root scalar has depth zero; the root array/object has depth one, and
/// each nested array/object adds one. Keys do not consume the value budget;
/// every JSON value (including the root and container nodes) does.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct JsonDecodeLimits {
    pub max_input_bytes: usize,
    pub max_nesting_depth: usize,
    pub max_string_bytes: usize,
    pub max_object_key_bytes: usize,
    pub max_array_items: usize,
    pub max_object_members: usize,
    pub max_total_values: usize,
}

impl JsonDecodeLimits {
    pub const COMMAND_REQUEST: Self = Self {
        max_input_bytes: 256 * 1024,
        max_nesting_depth: 32,
        max_string_bytes: 64 * 1024,
        max_object_key_bytes: 256,
        max_array_items: 4096,
        max_object_members: 256,
        max_total_values: 16_384,
    };
}

impl Default for JsonDecodeLimits {
    fn default() -> Self {
        Self::COMMAND_REQUEST
    }
}

/// Initial bounded single-document response and event-record targets.
/// Event-stream framing is a later checkpoint.
pub const DEFAULT_NON_STREAM_RESPONSE_MAX_BYTES: usize = 256 * 1024;
pub const DEFAULT_EVENT_RECORD_MAX_BYTES: usize = 64 * 1024;

/// Safe categories only: never stores hostile keys, values, or raw Serde errors.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JsonDecodeError {
    InputTooLarge,
    InvalidUtf8,
    MalformedJson,
    TrailingData,
    DuplicateObjectKey,
    NestingLimitExceeded,
    StringLimitExceeded,
    ObjectKeyLimitExceeded,
    ArrayLimitExceeded,
    ObjectMemberLimitExceeded,
    ValueLimitExceeded,
    SchemaViolation,
    UnknownCommandKind,
    PayloadSchemaViolation,
}

impl fmt::Display for JsonDecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::InputTooLarge => "JSON input exceeds its byte limit",
            Self::InvalidUtf8 => "JSON input is not UTF-8",
            Self::MalformedJson => "malformed JSON document",
            Self::TrailingData => "JSON document has trailing data",
            Self::DuplicateObjectKey => "JSON object has a duplicate property",
            Self::NestingLimitExceeded => "JSON nesting limit exceeded",
            Self::StringLimitExceeded => "JSON decoded string limit exceeded",
            Self::ObjectKeyLimitExceeded => "JSON decoded property-name limit exceeded",
            Self::ArrayLimitExceeded => "JSON array-item limit exceeded",
            Self::ObjectMemberLimitExceeded => "JSON object-member limit exceeded",
            Self::ValueLimitExceeded => "JSON aggregate-value limit exceeded",
            Self::SchemaViolation => "JSON value violates its protocol schema",
            Self::UnknownCommandKind => "unsupported semantic command kind",
            Self::PayloadSchemaViolation => "command payload violates its compiled schema",
        })
    }
}

impl std::error::Error for JsonDecodeError {}

/// A compiled command dispatcher may report only these safe categories.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CommandPayloadDecodeError {
    UnknownKind,
    SchemaViolation,
}

impl fmt::Display for CommandPayloadDecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::UnknownKind => "unsupported semantic command kind",
            Self::SchemaViolation => "command payload violates its compiled schema",
        })
    }
}

impl std::error::Error for CommandPayloadDecodeError {}

/// A compiled semantic payload identifies its own command kind. The codec
/// checks this against the wire kind before returning a command, so a mistaken
/// dispatcher cannot pair one kind with another kind's typed payload. It is
/// deliberately not implemented for serde_json::Value or RawValue.
pub trait TypedCommandPayload: Eq {
    /// Stable compiled semantic kind, independent of untrusted wire text.
    fn command_kind(&self) -> &'static str;
}

/// A compile-time command-kind/schema registry. The codec invokes this before
/// returning a command; implementations must recognize only compiled semantic
/// kinds and strict payload schemas, without consulting device/current Core state.
pub trait CommandPayloadDecoder {
    type Payload: TypedCommandPayload;

    fn decode_payload(
        kind: &CommandKind,
        payload: StrictJsonFragment<'_>,
    ) -> Result<Self::Payload, CommandPayloadDecodeError>;
}

/// A fragment from a complete document that already passed structural preflight.
/// Only the codec can construct it. A dispatcher can decode a concrete schema,
/// but cannot access raw JSON or return this fragment as a typed command payload.
pub struct StrictJsonFragment<'a> {
    raw: &'a RawValue,
}

impl StrictJsonFragment<'_> {
    pub fn decode<T: StrictJsonSchema>(self) -> Result<T, CommandPayloadDecodeError> {
        serde_json::from_str(self.raw.get()).map_err(|_| CommandPayloadDecodeError::SchemaViolation)
    }
}

/// Safe categories only; a partial writer buffer never becomes a success value.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JsonEncodeError {
    OutputTooLarge,
    SerializationFailure,
}

impl fmt::Display for JsonEncodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::OutputTooLarge => "JSON output exceeds its byte limit",
            Self::SerializationFailure => "JSON output cannot be serialized",
        })
    }
}

impl std::error::Error for JsonEncodeError {}
