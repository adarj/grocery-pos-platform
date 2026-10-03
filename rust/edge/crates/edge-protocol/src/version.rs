use std::fmt;

use serde::{Deserialize, Serialize};

/// Incompatible meanings require a different major version and route.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "u16", into = "u16")]
pub enum ProtocolMajor {
    V1,
}

impl From<ProtocolMajor> for u16 {
    fn from(value: ProtocolMajor) -> Self {
        match value {
            ProtocolMajor::V1 => 1,
        }
    }
}

impl TryFrom<u16> for ProtocolMajor {
    type Error = UnsupportedProtocolMajor;

    fn try_from(value: u16) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::V1),
            _ => Err(UnsupportedProtocolMajor),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct UnsupportedProtocolMajor;

impl fmt::Display for UnsupportedProtocolMajor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("unsupported Edge Protocol major version")
    }
}

impl std::error::Error for UnsupportedProtocolMajor {}

/// Additive minor metadata does not loosen strict requests or safety enum meanings.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProtocolVersion {
    pub major: ProtocolMajor,
    pub minor: u16,
}

impl ProtocolVersion {
    pub const CURRENT: Self = Self {
        major: ProtocolMajor::V1,
        minor: 1,
    };
    /// Historical 1.0 metadata for compatibility fixtures.
    pub const V1: Self = Self {
        major: ProtocolMajor::V1,
        minor: 0,
    };
}
