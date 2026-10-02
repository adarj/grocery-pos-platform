use std::fmt;

/// Initial type-level ceiling for semantic names/codes, subject to codec qualification.
pub const MAX_SEMANTIC_NAME_BYTES: usize = 256;

/// A value error that never includes the rejected input.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TextError {
    Empty,
    TooLong { max_bytes: usize },
}

impl fmt::Display for TextError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Empty => f.write_str("protocol text must not be empty"),
            Self::TooLong { max_bytes } => {
                write!(f, "protocol text exceeds {max_bytes} UTF-8 bytes")
            }
        }
    }
}

impl std::error::Error for TextError {}

// Shared mechanics only; each invocation still creates a distinct public type.
macro_rules! protocol_text {
    ($(#[$meta:meta])* $name:ident, $max_bytes:expr) => {
        $(#[$meta])*
        #[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, serde::Serialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            /// Validate nonempty text and its UTF-8 byte length, without a lexical grammar.
            pub fn new(value: impl Into<String>) -> Result<Self, crate::TextError> {
                let value = value.into();
                if value.is_empty() {
                    Err(crate::TextError::Empty)
                } else if value.len() > $max_bytes {
                    Err(crate::TextError::TooLong { max_bytes: $max_bytes })
                } else {
                    Ok(Self(value))
                }
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl TryFrom<String> for $name {
            type Error = crate::TextError;

            fn try_from(value: String) -> Result<Self, Self::Error> {
                Self::new(value)
            }
        }

        impl<'de> serde::Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                // This checks a decoded value, not allocation while reading hostile bytes.
                let value = <String as serde::Deserialize>::deserialize(deserializer)?;
                Self::new(value).map_err(serde::de::Error::custom)
            }
        }
    };
}

pub(crate) use protocol_text;
