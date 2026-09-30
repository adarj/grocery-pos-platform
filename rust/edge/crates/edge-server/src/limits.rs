use edge_protocol::{DEFAULT_EVENT_RECORD_MAX_BYTES, DEFAULT_NON_STREAM_RESPONSE_MAX_BYTES};
use std::time::Duration;

/// Initial implementation bounds, subject to M8.2.7 qualification.
#[derive(Clone, Debug)]
pub struct ServerLimits {
    pub max_connections: usize,
    pub control_mailbox_capacity: usize,
    pub header_bytes: usize,
    pub max_headers: usize,
    pub body_bytes: usize,
    pub response_bytes: usize,
    pub event_bytes: usize,
    pub header_timeout: Duration,
    pub body_timeout: Duration,
    pub control_timeout: Duration,
    pub response_timeout: Duration,
    pub executor_cadence: Duration,
    pub heartbeat_interval: Duration,
    #[cfg(feature = "qualification")]
    pub lose_first_accepted_response: bool,
    #[cfg(feature = "qualification")]
    pub event_chunk_bytes: usize,
}
impl Default for ServerLimits {
    fn default() -> Self {
        Self {
            max_connections: 16,
            control_mailbox_capacity: 64,
            header_bytes: 16 * 1024,
            max_headers: 32,
            body_bytes: 256 * 1024,
            response_bytes: DEFAULT_NON_STREAM_RESPONSE_MAX_BYTES,
            event_bytes: DEFAULT_EVENT_RECORD_MAX_BYTES,
            header_timeout: Duration::from_secs(5),
            body_timeout: Duration::from_secs(5),
            control_timeout: Duration::from_secs(5),
            response_timeout: Duration::from_secs(5),
            executor_cadence: Duration::from_millis(10),
            heartbeat_interval: Duration::from_secs(10),
            #[cfg(feature = "qualification")]
            lose_first_accepted_response: false,
            #[cfg(feature = "qualification")]
            event_chunk_bytes: DEFAULT_EVENT_RECORD_MAX_BYTES + 1,
        }
    }
}
impl ServerLimits {
    pub(crate) fn valid(&self) -> bool {
        [
            self.header_timeout,
            self.body_timeout,
            self.control_timeout,
            self.response_timeout,
            self.executor_cadence,
            self.heartbeat_interval,
        ]
        .iter()
        .all(|duration| std::time::Instant::now().checked_add(*duration).is_some())
            && self.max_connections > 0
            && self.control_mailbox_capacity > 0
            && self.header_bytes >= 8192
            && self.max_headers > 0
            && self.body_bytes > 0
            && self.response_bytes >= 256
            && self.event_bytes > 0
            && !self.header_timeout.is_zero()
            && !self.body_timeout.is_zero()
            && !self.control_timeout.is_zero()
            && !self.response_timeout.is_zero()
            && !self.executor_cadence.is_zero()
            && !self.heartbeat_interval.is_zero()
    }
}
