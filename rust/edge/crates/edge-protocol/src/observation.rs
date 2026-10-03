use std::fmt;

use serde::{Deserialize, Serialize};

use crate::TextError;

pub const MAX_BARCODE_BYTES: usize = 4096;

/// Opaque decoded input, including spaces, controls and leading zeros. No
/// symbology, normalization or business interpretation is implied. Wire content
/// is private; diagnostics deliberately omit it.
#[derive(Clone, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct BarcodeValue(String);

impl BarcodeValue {
    pub fn new(value: impl Into<String>) -> Result<Self, TextError> {
        let value = value.into();
        if value.is_empty() {
            Err(TextError::Empty)
        } else if value.len() > MAX_BARCODE_BYTES {
            Err(TextError::TooLong {
                max_bytes: MAX_BARCODE_BYTES,
            })
        } else {
            Ok(Self(value))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for BarcodeValue {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("BarcodeValue([redacted])")
    }
}

impl<'de> Deserialize<'de> for BarcodeValue {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::new(String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

/// Closed semantic input vocabulary. Sources supply values only, never epochs,
/// revisions, sequence numbers or wire events.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", deny_unknown_fields)]
pub enum DeviceObservation {
    #[serde(rename = "scanner.barcode")]
    ScannerBarcode { barcode: BarcodeValue },
}

impl DeviceObservation {
    pub fn required_capability(&self) -> &'static str {
        match self {
            Self::ScannerBarcode { .. } => "scanner.barcode",
        }
    }
}
