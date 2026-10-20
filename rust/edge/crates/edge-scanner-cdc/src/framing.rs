//! Incremental, fail-closed CRLF framing. No read boundary has semantic meaning.

use std::{collections::VecDeque, fmt};

use edge_protocol::{BarcodeValue, TextError};

use crate::profile::{
    MAX_INPUT_CHUNK_BYTES, MAX_PAYLOAD_BYTES, MAX_QUEUED_RECORDS, MAX_SYNC_PREFIX_BYTES,
};

/// Alignment is independent of transport open/idle state and Core activation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FramingState {
    Unsynchronized,
    Aligned,
    Failed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FramingError {
    EmptyRecord,
    InvalidUtf8,
    PayloadTooLong,
    BareLf,
    CrNotFollowedByLf,
    QueueCapacityExceeded,
    SynchronizationFailed,
    InputChunkTooLarge,
    InputAfterFailure,
}

impl fmt::Display for FramingError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::EmptyRecord => "CDC record is empty",
            Self::InvalidUtf8 => "CDC record is not valid UTF-8",
            Self::PayloadTooLong => "CDC payload exceeds byte limit",
            Self::BareLf => "CDC record contains a bare LF",
            Self::CrNotFollowedByLf => "CDC CR is not followed by LF",
            Self::QueueCapacityExceeded => "CDC completed-record queue capacity exceeded",
            Self::SynchronizationFailed => "CDC synchronization prefix is malformed or too long",
            Self::InputChunkTooLarge => "CDC input chunk exceeds per-call byte limit",
            Self::InputAfterFailure => "CDC parser has already failed",
        })
    }
}

impl std::error::Error for FramingError {}

/// A bounded stream decoder with irreversible failure and redacted diagnostics.
///
/// It stores at most 4,096 partial payload bytes, one pending-CR flag and 16
/// completed records. Each `feed` visits at most `MAX_INPUT_CHUNK_BYTES` bytes.
/// `next_record` transfers at most one value; a future source must additionally
/// enforce its own one-record-per-poll and acquisition-work budgets.
///
/// Failure discards all undelivered records and partial bytes. Previously taken
/// records cannot be retracted. There is deliberately no reset or realignment
/// method: recovery needs a new parser and a new, justified transport lifetime.
pub struct Framer {
    state: FramingState,
    partial: Vec<u8>,
    pending_cr: bool,
    sync_bytes: usize,
    records: VecDeque<BarcodeValue>,
    failure: Option<FramingError>,
}

impl fmt::Debug for Framer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Framer")
            .field("state", &self.state)
            .field("partial_bytes", &self.partial.len())
            .field("pending_cr", &self.pending_cr)
            .field("sync_bytes", &self.sync_bytes)
            .field("queued_records", &self.records.len())
            .field("failure", &self.failure)
            .finish()
    }
}

impl Default for Framer {
    fn default() -> Self {
        Self::new()
    }
}

impl Framer {
    /// Start at unknown alignment. Discard through the first complete CRLF
    /// boundary (including its preceding bytes); never emit that initial suffix.
    /// Discarded bytes need not be UTF-8. Bare LF, CR followed by non-LF, or more
    /// than `MAX_SYNC_PREFIX_BYTES` total discarded bytes fail synchronization.
    /// Empty input, inactivity and chunk boundaries establish no alignment.
    pub fn new() -> Self {
        Self {
            state: FramingState::Unsynchronized,
            partial: Vec::with_capacity(MAX_PAYLOAD_BYTES),
            pending_cr: false,
            sync_bytes: 0,
            records: VecDeque::with_capacity(MAX_QUEUED_RECORDS),
            failure: None,
        }
    }

    /// Start aligned ONLY when a trusted transport owner has externally proved
    /// that the next byte begins a record. Opening a device, an empty read,
    /// elapsed time, enumeration and Core activation are not such proof.
    ///
    /// This pure constructor does not flush host input or establish an
    /// acquisition cutoff. Those policies remain WP2 work.
    pub fn at_record_boundary() -> Self {
        Self {
            state: FramingState::Aligned,
            ..Self::new()
        }
    }

    pub fn state(&self) -> FramingState {
        self.state
    }

    /// The first failure cause, retained without input bytes or UTF-8 details.
    pub fn failure(&self) -> Option<FramingError> {
        self.failure
    }

    /// Consume one bounded chunk. Oversized chunks fail before any scanning.
    /// Any failure clears *all* queued records, including earlier feed results.
    /// Subsequent calls, even with empty input, return `InputAfterFailure`.
    pub fn feed(&mut self, bytes: &[u8]) -> Result<(), FramingError> {
        if self.state == FramingState::Failed {
            return Err(FramingError::InputAfterFailure);
        }
        if bytes.len() > MAX_INPUT_CHUNK_BYTES {
            return self.fail(FramingError::InputChunkTooLarge);
        }
        for &byte in bytes {
            let result = if self.state == FramingState::Unsynchronized {
                self.synchronize(byte)
            } else {
                self.accept_aligned(byte)
            };
            if let Err(error) = result {
                return self.fail(error);
            }
        }
        Ok(())
    }

    /// Transfer one completed record without copying its payload. Never emits
    /// unsynchronized data or anything after a failure; never deduplicates.
    pub fn next_record(&mut self) -> Option<BarcodeValue> {
        self.records.pop_front()
    }

    pub fn queued_records(&self) -> usize {
        self.records.len()
    }

    fn synchronize(&mut self, byte: u8) -> Result<(), FramingError> {
        if self.sync_bytes == MAX_SYNC_PREFIX_BYTES {
            return Err(FramingError::SynchronizationFailed);
        }
        self.sync_bytes += 1; // Increment only below the fixed bound.
        if self.pending_cr {
            if byte != b'\n' {
                return Err(FramingError::SynchronizationFailed);
            }
            self.pending_cr = false;
            self.sync_bytes = 0;
            self.state = FramingState::Aligned;
        } else {
            match byte {
                b'\r' => self.pending_cr = true,
                b'\n' => return Err(FramingError::SynchronizationFailed),
                _ => {}
            }
        }
        Ok(())
    }

    fn accept_aligned(&mut self, byte: u8) -> Result<(), FramingError> {
        if self.pending_cr {
            if byte != b'\n' {
                return Err(FramingError::CrNotFollowedByLf);
            }
            self.pending_cr = false;
            return self.complete_record();
        }
        match byte {
            b'\r' => self.pending_cr = true,
            b'\n' => return Err(FramingError::BareLf),
            _ => {
                if self.partial.len() == MAX_PAYLOAD_BYTES {
                    return Err(FramingError::PayloadTooLong);
                }
                self.partial.push(byte);
            }
        }
        Ok(())
    }

    fn complete_record(&mut self) -> Result<(), FramingError> {
        if self.partial.is_empty() {
            return Err(FramingError::EmptyRecord);
        }
        let text = String::from_utf8(std::mem::take(&mut self.partial))
            .map_err(|_| FramingError::InvalidUtf8)?;
        if self.records.len() == MAX_QUEUED_RECORDS {
            return Err(FramingError::QueueCapacityExceeded);
        }
        // String::from_utf8 and BarcodeValue::new move the same payload
        // allocation. Neither needs a second barcode copy.
        let record = BarcodeValue::new(text).map_err(|error| match error {
            TextError::Empty => FramingError::EmptyRecord,
            TextError::TooLong { .. } => FramingError::PayloadTooLong,
        })?;
        self.records.push_back(record);
        self.partial = Vec::with_capacity(MAX_PAYLOAD_BYTES);
        Ok(())
    }

    fn fail(&mut self, error: FramingError) -> Result<(), FramingError> {
        self.state = FramingState::Failed;
        self.failure = Some(error);
        self.partial = Vec::new();
        self.records.clear();
        self.pending_cr = false;
        self.sync_bytes = 0;
        Err(error)
    }
}
