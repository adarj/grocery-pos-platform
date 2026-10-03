//! Privileged restart-only configuration, discovery, reconciliation and binding
//! composition. Fresh authorization and owned attachment runtime installation
//! are required before Core activation; presence alone grants no authority.

pub mod binding;
pub mod catalog;
pub mod config;
pub mod discovery;
#[cfg(target_os = "linux")]
pub mod linux;
pub mod reconcile;

pub const MAX_CONFIG_BYTES: usize = 65_536;
pub const MAX_DEVICES: usize = 32;
pub const MAX_CAPABILITIES_PER_DEVICE: usize = 32;
pub const MAX_CANDIDATES: usize = 256;
pub const MAX_SERIAL_BYTES: usize = 256;
pub const MAX_TOPOLOGY_BYTES: usize = 512;
pub const MAX_SYSFS_PATH_BYTES: usize = 1_024;

/// Configuration names are deliberately narrower than opaque protocol text.
fn valid_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= edge_protocol::MAX_IDENTIFIER_BYTES
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b))
}
