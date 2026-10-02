use crate::text::protocol_text;

/// Initial type-level identifier ceiling; strict decoding checks it after
/// bounded structural parsing of the containing JSON document.
pub const MAX_IDENTIFIER_BYTES: usize = 256;

protocol_text!(
    /// One edge process lifetime. No UUID syntax, ordering, or time semantics.
    AgentInstanceId, MAX_IDENTIFIER_BYTES
);
protocol_text!(
    /// Stable privileged-configured logical device slot, surviving hardware replacement.
    DeviceId, MAX_IDENTIFIER_BYTES
);
protocol_text!(
    /// One exact successful physical binding epoch.
    BindingInstanceId, MAX_IDENTIFIER_BYTES
);
protocol_text!(
    /// Racket's operation identity. New semantic attempts require fresh unpredictable IDs.
    ///
    /// Distinct identities cannot be accidentally interchanged:
    /// ```compile_fail
    /// use edge_protocol::{CommandId, RequestId};
    /// let command_id: CommandId = RequestId::new("synthetic-request").unwrap();
    /// ```
    CommandId, MAX_IDENTIFIER_BYTES
);
protocol_text!(
    /// One HTTP request attempt; transport retries change this ID only.
    RequestId, MAX_IDENTIFIER_BYTES
);
