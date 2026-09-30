use std::collections::BTreeSet;

use serde::Deserialize;
use serde::de::{self, DeserializeSeed, MapAccess, SeqAccess, Visitor};
use serde_json::value::RawValue;

use super::{
    CommandPayloadDecodeError, CommandPayloadDecoder, JsonDecodeError, JsonDecodeLimits,
    StrictJsonFragment, StrictJsonSchema, TypedCommandPayload,
};
use crate::{
    AgentInstanceId, AgentUptimeMs, BindingInstanceId, CommandId, CommandKind, CommandSubmission,
    CommandTimeoutMs, DeviceId, RequestId,
};

struct Traversal {
    limits: JsonDecodeLimits,
    total_values: usize,
    failure: Option<JsonDecodeError>,
}

impl Traversal {
    fn fail<E: de::Error>(&mut self, reason: JsonDecodeError) -> E {
        self.failure = Some(reason);
        E::custom("invalid JSON structure")
    }

    fn count_value<E: de::Error>(&mut self) -> Result<(), E> {
        self.total_values = self
            .total_values
            .checked_add(1)
            .ok_or_else(|| self.fail(JsonDecodeError::ValueLimitExceeded))?;
        if self.total_values > self.limits.max_total_values {
            return Err(self.fail(JsonDecodeError::ValueLimitExceeded));
        }
        Ok(())
    }
}

struct WalkSeed<'a> {
    traversal: &'a mut Traversal,
    parent_depth: usize,
}

impl<'de> DeserializeSeed<'de> for WalkSeed<'_> {
    type Value = ();

    fn deserialize<D: de::Deserializer<'de>>(
        self,
        deserializer: D,
    ) -> Result<Self::Value, D::Error> {
        self.traversal.count_value()?;
        deserializer.deserialize_any(WalkVisitor {
            traversal: self.traversal,
            parent_depth: self.parent_depth,
        })
    }
}

struct WalkVisitor<'a> {
    traversal: &'a mut Traversal,
    parent_depth: usize,
}

impl<'de> Visitor<'de> for WalkVisitor<'_> {
    type Value = ();

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("a bounded JSON value")
    }

    fn visit_unit<E: de::Error>(self) -> Result<Self::Value, E> {
        Ok(())
    }

    fn visit_bool<E: de::Error>(self, _value: bool) -> Result<Self::Value, E> {
        Ok(())
    }

    fn visit_i64<E: de::Error>(self, _value: i64) -> Result<Self::Value, E> {
        Ok(())
    }

    fn visit_u64<E: de::Error>(self, _value: u64) -> Result<Self::Value, E> {
        Ok(())
    }

    fn visit_f64<E: de::Error>(self, _value: f64) -> Result<Self::Value, E> {
        Ok(())
    }

    fn visit_str<E: de::Error>(self, value: &str) -> Result<Self::Value, E> {
        if value.len() > self.traversal.limits.max_string_bytes {
            return Err(self.traversal.fail(JsonDecodeError::StringLimitExceeded));
        }
        Ok(())
    }

    fn visit_string<E: de::Error>(self, value: String) -> Result<Self::Value, E> {
        self.visit_str(&value)
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
        let depth = self
            .parent_depth
            .checked_add(1)
            .ok_or_else(|| self.traversal.fail(JsonDecodeError::NestingLimitExceeded))?;
        if depth > self.traversal.limits.max_nesting_depth {
            return Err(self.traversal.fail(JsonDecodeError::NestingLimitExceeded));
        }
        let mut items = 0_usize;
        while seq
            .next_element_seed(WalkSeed {
                traversal: self.traversal,
                parent_depth: depth,
            })?
            .is_some()
        {
            items = items
                .checked_add(1)
                .ok_or_else(|| self.traversal.fail(JsonDecodeError::ArrayLimitExceeded))?;
            if items > self.traversal.limits.max_array_items {
                return Err(self.traversal.fail(JsonDecodeError::ArrayLimitExceeded));
            }
        }
        Ok(())
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        let depth = self
            .parent_depth
            .checked_add(1)
            .ok_or_else(|| self.traversal.fail(JsonDecodeError::NestingLimitExceeded))?;
        if depth > self.traversal.limits.max_nesting_depth {
            return Err(self.traversal.fail(JsonDecodeError::NestingLimitExceeded));
        }
        // The body limit bounds temporary key decoding. The per-object member
        // and decoded-key bounds then cap this duplicate-detection set.
        let mut keys = BTreeSet::new();
        let mut members = 0_usize;
        while let Some(key) = map.next_key::<String>()? {
            if key.len() > self.traversal.limits.max_object_key_bytes {
                return Err(self.traversal.fail(JsonDecodeError::ObjectKeyLimitExceeded));
            }
            if !keys.insert(key) {
                return Err(self.traversal.fail(JsonDecodeError::DuplicateObjectKey));
            }
            members = members.checked_add(1).ok_or_else(|| {
                self.traversal
                    .fail(JsonDecodeError::ObjectMemberLimitExceeded)
            })?;
            if members > self.traversal.limits.max_object_members {
                return Err(self
                    .traversal
                    .fail(JsonDecodeError::ObjectMemberLimitExceeded));
            }
            map.next_value_seed(WalkSeed {
                traversal: self.traversal,
                parent_depth: depth,
            })?;
        }
        Ok(())
    }
}

fn preflight(bytes: &[u8], limits: JsonDecodeLimits) -> Result<&str, JsonDecodeError> {
    if bytes.len() > limits.max_input_bytes {
        return Err(JsonDecodeError::InputTooLarge);
    }
    let text = std::str::from_utf8(bytes).map_err(|_| JsonDecodeError::InvalidUtf8)?;
    let mut deserializer = serde_json::Deserializer::from_str(text);
    let mut traversal = Traversal {
        limits,
        total_values: 0,
        failure: None,
    };
    if (WalkSeed {
        traversal: &mut traversal,
        parent_depth: 0,
    })
    .deserialize(&mut deserializer)
    .is_err()
    {
        return Err(traversal.failure.unwrap_or(JsonDecodeError::MalformedJson));
    }
    deserializer
        .end()
        .map_err(|_| JsonDecodeError::TrailingData)?;
    Ok(text)
}

/// Decode one complete bounded document into a fixed, opted-in protocol schema.
/// Command requests must instead use decode_command_strict so kind and payload
/// are bound to one compiled schema before the command reaches Core.
pub fn decode_json_strict<T: StrictJsonSchema>(
    bytes: &[u8],
    limits: JsonDecodeLimits,
) -> Result<T, JsonDecodeError> {
    let text = preflight(bytes, limits)?;
    serde_json::from_str(text).map_err(|_| JsonDecodeError::SchemaViolation)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawCommandSubmission<'a> {
    request_id: RequestId,
    command_id: CommandId,
    expected_agent_instance_id: AgentInstanceId,
    device_id: DeviceId,
    expected_binding_instance_id: BindingInstanceId,
    not_after_agent_uptime_ms: AgentUptimeMs,
    kind: CommandKind,
    timeout_ms: CommandTimeoutMs,
    #[serde(borrow)]
    payload: &'a RawValue,
}

/// Decode a command envelope, then bind its kind and preflighted payload to a
/// compiled typed schema. This performs no device, freshness, or Core admission.
pub fn decode_command_strict<D: CommandPayloadDecoder>(
    bytes: &[u8],
    limits: JsonDecodeLimits,
) -> Result<CommandSubmission<D::Payload>, JsonDecodeError> {
    let text = preflight(bytes, limits)?;
    let raw: RawCommandSubmission<'_> =
        serde_json::from_str(text).map_err(|_| JsonDecodeError::SchemaViolation)?;
    let payload =
        D::decode_payload(&raw.kind, StrictJsonFragment { raw: raw.payload }).map_err(|error| {
            match error {
                CommandPayloadDecodeError::UnknownKind => JsonDecodeError::UnknownCommandKind,
                CommandPayloadDecodeError::SchemaViolation => {
                    JsonDecodeError::PayloadSchemaViolation
                }
                CommandPayloadDecodeError::SemanticViolation => {
                    JsonDecodeError::PayloadSemanticViolation
                }
            }
        })?;
    if payload.command_kind() != raw.kind.as_str() {
        return Err(JsonDecodeError::PayloadSchemaViolation);
    }
    Ok(CommandSubmission {
        request_id: raw.request_id,
        command_id: raw.command_id,
        expected_agent_instance_id: raw.expected_agent_instance_id,
        device_id: raw.device_id,
        expected_binding_instance_id: raw.expected_binding_instance_id,
        not_after_agent_uptime_ms: raw.not_after_agent_uptime_ms,
        kind: raw.kind,
        timeout_ms: raw.timeout_ms,
        payload,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nesting_depth_counts_containers_including_the_root() {
        let exact = format!("{}0{}", "[".repeat(32), "]".repeat(32));
        let too_deep = format!("{}0{}", "[".repeat(33), "]".repeat(33));
        assert!(preflight(exact.as_bytes(), JsonDecodeLimits::default()).is_ok());
        assert_eq!(
            preflight(too_deep.as_bytes(), JsonDecodeLimits::default()),
            Err(JsonDecodeError::NestingLimitExceeded)
        );
        assert!(
            preflight(
                b"0",
                JsonDecodeLimits {
                    max_nesting_depth: 0,
                    ..Default::default()
                }
            )
            .is_ok()
        );
        assert_eq!(
            preflight(
                b"[]",
                JsonDecodeLimits {
                    max_nesting_depth: 0,
                    ..Default::default()
                }
            ),
            Err(JsonDecodeError::NestingLimitExceeded)
        );
    }
}
