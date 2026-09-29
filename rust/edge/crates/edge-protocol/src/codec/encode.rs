use std::io::{self, Write};

use serde::Serialize;

use super::JsonEncodeError;

struct BoundedWriter {
    bytes: Vec<u8>,
    max_bytes: usize,
    exceeded: bool,
}

impl Write for BoundedWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        if buffer.len() > self.max_bytes.saturating_sub(self.bytes.len()) {
            self.exceeded = true;
            return Err(io::Error::other("JSON output byte limit exceeded"));
        }
        self.bytes.extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Serialize one JSON record without ever constructing an oversized document.
/// A failed partial buffer is discarded, never returned as a valid JSON value.
pub fn encode_json_bounded<T: Serialize>(
    value: &T,
    max_bytes: usize,
) -> Result<Vec<u8>, JsonEncodeError> {
    let mut writer = BoundedWriter {
        bytes: Vec::new(),
        max_bytes,
        exceeded: false,
    };
    match serde_json::to_writer(&mut writer, value) {
        Ok(()) => Ok(writer.bytes),
        Err(_) if writer.exceeded => Err(JsonEncodeError::OutputTooLarge),
        Err(_) => Err(JsonEncodeError::SerializationFailure),
    }
}
