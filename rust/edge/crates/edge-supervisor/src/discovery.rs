use std::collections::BTreeSet;
use std::fmt;

use crate::config::UsbSelector;
use crate::{MAX_CANDIDATES, MAX_SERIAL_BYTES, MAX_SYSFS_PATH_BYTES, MAX_TOPOLOGY_BYTES};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DiscoveryError {
    Io,
    InventoryTooLarge,
    ScanTooLarge,
    InvalidAttribute,
    DuplicateCandidate,
}

impl fmt::Display for DiscoveryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "edge discovery snapshot rejected: {self:?}")
    }
}

impl std::error::Error for DiscoveryError {}

fn valid_text(value: &str, bound: usize) -> bool {
    !value.is_empty() && value.len() <= bound && !value.chars().any(char::is_control)
}

macro_rules! private_text {
    ($name:ident, $bound:expr) => {
        private_text!($name, $bound, |_| true);
    };
    ($name:ident, $bound:expr, $validate:expr) => {
        #[derive(Clone, Eq, Ord, PartialEq, PartialOrd)]
        pub struct $name(String);

        impl $name {
            pub fn new(value: &str) -> Result<Self, DiscoveryError> {
                if !valid_text(value, $bound) || !($validate)(value) {
                    return Err(DiscoveryError::InvalidAttribute);
                }
                Ok(Self(value.to_owned()))
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl fmt::Debug for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(concat!(stringify!($name), "([redacted])"))
            }
        }
    };
}

private_text!(Serial, MAX_SERIAL_BYTES);
private_text!(CandidateId, MAX_SYSFS_PATH_BYTES);
// Producers must resolve filesystem symlinks before constructing a snapshot.
// Lexical aliases are rejected here without touching the host filesystem.
private_text!(SysfsPath, MAX_SYSFS_PATH_BYTES, |value: &str| {
    value.starts_with('/')
        && value
            .split('/')
            .skip(1)
            .all(|part| !part.is_empty() && part != "." && part != "..")
});

/// A bus-number-free, host-specific USB topology selector. Controller routing,
/// companion-controller/speed changes, or firmware can invalidate it. It is
/// operational matching, never immutable connector identity or attestation.
/// Root hubs on indistinguishable controller/revision paths may
/// collide; reconciliation treats multiple matches as ambiguous, never a winner.
#[derive(Clone, Eq, Ord, PartialEq, PartialOrd)]
pub struct Topology(String);

impl fmt::Debug for Topology {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Topology([redacted])")
    }
}

impl Topology {
    pub fn new(value: &str) -> Result<Self, DiscoveryError> {
        if !valid_text(value, MAX_TOPOLOGY_BYTES) {
            return Err(DiscoveryError::InvalidAttribute);
        }
        let Some((controller, rest)) = value
            .strip_prefix("sysfs:")
            .and_then(|v| v.split_once(";usb="))
        else {
            return Err(DiscoveryError::InvalidAttribute);
        };
        let Some((revision, ports)) = rest.split_once(";ports=") else {
            return Err(DiscoveryError::InvalidAttribute);
        };
        if !controller.starts_with("/devices/")
            || controller.ends_with('/')
            || controller.split('/').skip(1).any(|part| {
                part.is_empty()
                    || part == "."
                    || part == ".."
                    || part.strip_prefix("usb").is_some_and(|number| {
                        !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit())
                    })
                    || !part
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"._:-".contains(&b))
            })
            || revision.len() != 4
            || revision.as_bytes()[1] != b'.'
            || !revision
                .bytes()
                .enumerate()
                .all(|(i, b)| i == 1 || b.is_ascii_digit())
            || !valid_ports(ports)
        {
            return Err(DiscoveryError::InvalidAttribute);
        }
        Ok(Self(value.to_owned()))
    }

    pub fn from_parts(
        controller: &str,
        revision: &str,
        ports: &str,
    ) -> Result<Self, DiscoveryError> {
        // Check before allocating a formatted value from potentially hostile attributes.
        if controller.len() > MAX_TOPOLOGY_BYTES || revision.len() != 4 || ports.len() > 32 {
            return Err(DiscoveryError::InvalidAttribute);
        }
        Self::new(&format!("sysfs:{controller};usb={revision};ports={ports}"))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

pub(crate) fn valid_ports(ports: &str) -> bool {
    if ports == "0" {
        return true;
    } // Root hub, not a device address.
    let mut count = 0;
    for part in ports.split('.') {
        count += 1;
        if count > 7
            || part.is_empty()
            || part.starts_with('0')
            || !part.bytes().all(|b| b.is_ascii_digit())
            || part.parse::<u8>().ok().filter(|p| *p != 0).is_none()
        {
            return false;
        }
    }
    count > 0
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DiscoveryBus {
    Usb,
    /// Defensive rejection marker, not support for another discovery backend.
    Unsupported,
}

/// One physical USB device, not a HID/input/serial interface. No descriptor
/// dump, devnode, serialization, or public protocol conversion exists.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiscoveryCandidate {
    pub id: CandidateId,
    pub bus: DiscoveryBus,
    pub vendor_id: u16,
    pub product_id: u16,
    pub serial: Option<Serial>,
    pub topology: Topology,
    pub sysfs_path: SysfsPath,
}

impl UsbSelector {
    pub fn matches(&self, candidate: &DiscoveryCandidate) -> bool {
        candidate.bus == DiscoveryBus::Usb
            && self.vendor_id == candidate.vendor_id
            && self.product_id == candidate.product_id
            && self
                .serial
                .as_ref()
                .is_none_or(|serial| candidate.serial.as_ref() == Some(serial))
            && self
                .topology
                .as_ref()
                .is_none_or(|topology| &candidate.topology == topology)
    }
}

#[derive(Clone, Debug)]
pub struct DiscoverySnapshot(Vec<DiscoveryCandidate>);

impl DiscoverySnapshot {
    pub fn new(mut candidates: Vec<DiscoveryCandidate>) -> Result<Self, DiscoveryError> {
        if candidates.len() > MAX_CANDIDATES {
            return Err(DiscoveryError::InventoryTooLarge);
        }
        let mut ids = BTreeSet::new();
        let mut paths = BTreeSet::new();
        for candidate in &candidates {
            if !ids.insert(&candidate.id) || !paths.insert(&candidate.sysfs_path) {
                return Err(DiscoveryError::DuplicateCandidate);
            }
        }
        candidates.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(Self(candidates))
    }

    pub fn candidates(&self) -> &[DiscoveryCandidate] {
        &self.0
    }
}

/// Future add/remove/change notifications only wake a caller of this method;
/// notification payloads must never replace a complete current snapshot.
pub trait DiscoverySource {
    fn snapshot(&self) -> Result<DiscoverySnapshot, DiscoveryError>;
}
