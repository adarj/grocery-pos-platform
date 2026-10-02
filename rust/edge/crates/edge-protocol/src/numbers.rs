use std::num::NonZeroU64;

use serde::{Deserialize, Serialize};

macro_rules! integer_domain {
    ($(#[$meta:meta])* $name:ident) => {
        $(#[$meta])*
        #[derive(Clone, Copy, Debug, Default, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(u64);

        impl $name {
            pub const fn new(value: u64) -> Self {
                Self(value)
            }

            pub const fn get(self) -> u64 {
                self.0
            }
        }
    };
}

integer_domain!(
    /// Exact monotonic milliseconds since agent startup, including freshness deadlines.
    /// No wall-clock interpretation or unchecked arithmetic is supplied.
    AgentUptimeMs
);
integer_domain!(
    /// Ordering of one logical device's snapshots within an agent epoch.
    StateRevision
);
integer_domain!(
    /// Ordering of externally visible state events within an agent epoch.
    EventSequence
);
integer_domain!(
    /// Snapshot boundary in the global event sequence; zero may precede all events.
    EventCursor
);

/// Positive acceptance-relative timeout in milliseconds, including queue time.
/// The later admission policy enforces the runtime maximum separately.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct CommandTimeoutMs(NonZeroU64);

impl CommandTimeoutMs {
    pub const fn new(value: u64) -> Option<Self> {
        match NonZeroU64::new(value) {
            Some(value) => Some(Self(value)),
            None => None,
        }
    }

    pub const fn get(self) -> u64 {
        self.0.get()
    }
}
