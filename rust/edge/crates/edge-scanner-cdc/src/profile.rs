//! Reference profile metadata, not discovery, device authorization or a working
//! scanner driver. The selected USB CDC Host identity is 05e0:1701, distinct from
//! the keyboard HID identity 05e0:1200. Linux attachment verification is WP2 work.
//!
//! The physical profile accepts nonempty UTF-8 without CR/LF payload bytes and
//! removes exactly one CRLF terminator. Other controls, NUL, spaces, case and
//! leading zeros are preserved. This is narrower than the generic Edge barcode
//! domain, which permits embedded CR/LF. No symbology interpretation is implied.

pub const DS2208_CDC_VENDOR_ID: u16 = 0x05e0;
pub const DS2208_CDC_PRODUCT_ID: u16 = 0x1701;

/// Payload bytes, excluding CRLF; identical to the existing protocol ceiling.
pub const MAX_PAYLOAD_BYTES: usize = edge_protocol::MAX_BARCODE_BYTES;

pub const MAX_QUEUED_RECORDS: usize = 16;

/// Per-call work bound: enough for one maximum-size payload and its delimiter.
/// This is not a physical read size or a future per-poll acquisition budget.
pub const MAX_INPUT_CHUNK_BYTES: usize = MAX_PAYLOAD_BYTES + 2;

/// Discard at most one maximum-size frame, including CRLF, to find alignment.
/// A longer or malformed prefix makes continuity untrustworthy.
pub const MAX_SYNC_PREFIX_BYTES: usize = MAX_PAYLOAD_BYTES + 2;
