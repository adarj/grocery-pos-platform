use serde::{Deserialize, Serialize};

use crate::MAX_SEMANTIC_NAME_BYTES;
use crate::text::protocol_text;

/// Initial type-level ceiling for authored safe error messages, not a logging budget.
pub const MAX_ERROR_MESSAGE_BYTES: usize = 1024;

protocol_text!(
    /// Stable semantic machine code; named codes arrive with implemented behaviors.
    ErrorCode, MAX_SEMANTIC_NAME_BYTES
);
protocol_text!(
    /// Authored/sanitized explanation. Length validation cannot prove content is safe.
    /// Never construct this from raw requests, device traffic, descriptors, or exception dumps.
    SafeErrorMessage, MAX_ERROR_MESSAGE_BYTES
);

/// Safe public error vocabulary, without raw driver errors or a retry-policy flag.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProtocolError {
    pub code: ErrorCode,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<SafeErrorMessage>,
}
