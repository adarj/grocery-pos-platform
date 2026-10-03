use std::collections::{BTreeMap, BTreeSet};
use std::fs::File;
use std::io::Read;
use std::path::Path;

use edge_core::{CoreDeviceSeed, ResourceId};
use edge_protocol::{
    AdapterKind, AgentInstanceId, Capability, DeviceAvailability, DeviceId, DeviceSnapshot,
    StateRevision,
};
use serde::Deserialize;

use crate::catalog::{AdapterCatalog, SelectorFamily};
use crate::discovery::{Serial, Topology};
use crate::{MAX_CAPABILITIES_PER_DEVICE, MAX_CONFIG_BYTES, MAX_DEVICES, valid_name};

pub const PRODUCTION_CONFIG_PATH: &str = "/etc/grocery-pos/edge.toml";

/// Authored errors deliberately discard TOML excerpts, paths and descriptors.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConfigError {
    Io,
    TooLarge,
    InvalidUtf8,
    InvalidToml,
    UnsupportedSchema,
    TooManyDevices,
    DuplicateDevice,
    InvalidName,
    InvalidCapabilities,
    UnknownAdapter,
    UnsupportedCapability,
    UnsupportedSelector,
    InvalidSelector,
}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "edge configuration rejected: {self:?}")
    }
}

impl std::error::Error for ConfigError {}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawConfiguration {
    schema_version: u32,
    devices: Vec<RawSlot>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawSlot {
    device_id: DeviceId,
    enabled: bool,
    adapter_kind: AdapterKind,
    allowed_capabilities: Vec<Capability>,
    selector: RawSelector,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum RawSelector {
    Usb {
        vendor_id: u16,
        product_id: u16,
        serial: Option<String>,
        topology: Option<String>,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UsbSelector {
    pub vendor_id: u16,
    pub product_id: u16,
    pub serial: Option<Serial>,
    pub topology: Option<Topology>,
}

#[derive(Clone, Debug)]
pub struct ConfiguredSlot {
    pub(crate) device_id: DeviceId,
    pub(crate) enabled: bool,
    pub(crate) adapter_kind: AdapterKind,
    pub(crate) allowed_capabilities: BTreeSet<Capability>,
    pub(crate) command_groups: BTreeMap<Capability, u16>,
    pub(crate) selector: UsbSelector,
}

impl ConfiguredSlot {
    pub fn device_id(&self) -> &DeviceId {
        &self.device_id
    }

    pub fn selector(&self) -> &UsbSelector {
        &self.selector
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }
}

#[derive(Clone, Debug)]
pub struct Configuration {
    // Sorted identity order also fixes seed/resource allocation order.
    slots: BTreeMap<DeviceId, ConfiguredSlot>,
}

impl Configuration {
    pub fn load(path: impl AsRef<Path>, catalog: &AdapterCatalog) -> Result<Self, ConfigError> {
        let file = File::open(path).map_err(|_| ConfigError::Io)?;
        let mut bytes = Vec::new();
        file.take((MAX_CONFIG_BYTES + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| ConfigError::Io)?;
        Self::parse(&bytes, catalog)
    }

    pub fn parse(bytes: &[u8], catalog: &AdapterCatalog) -> Result<Self, ConfigError> {
        if bytes.len() > MAX_CONFIG_BYTES {
            return Err(ConfigError::TooLarge);
        }
        let text = std::str::from_utf8(bytes).map_err(|_| ConfigError::InvalidUtf8)?;
        let raw: RawConfiguration = toml::from_str(text).map_err(|_| ConfigError::InvalidToml)?;
        if raw.schema_version != 1 {
            return Err(ConfigError::UnsupportedSchema);
        }
        if raw.devices.len() > MAX_DEVICES {
            return Err(ConfigError::TooManyDevices);
        }
        let mut slots = BTreeMap::new();
        for slot in raw.devices {
            if !valid_name(slot.device_id.as_str())
                || !valid_name(slot.adapter_kind.as_str())
                || slot
                    .allowed_capabilities
                    .iter()
                    .any(|cap| !valid_name(cap.as_str()))
            {
                return Err(ConfigError::InvalidName);
            }
            let count = slot.allowed_capabilities.len();
            if count == 0 || count > MAX_CAPABILITIES_PER_DEVICE {
                return Err(ConfigError::InvalidCapabilities);
            }
            let allowed_capabilities: BTreeSet<_> = slot.allowed_capabilities.into_iter().collect();
            if allowed_capabilities.len() != count {
                return Err(ConfigError::InvalidCapabilities);
            }
            let adapter = catalog
                .get(&slot.adapter_kind)
                .ok_or(ConfigError::UnknownAdapter)?;
            if !allowed_capabilities.is_subset(&adapter.capabilities) {
                return Err(ConfigError::UnsupportedCapability);
            }
            let selector = match slot.selector {
                RawSelector::Usb {
                    vendor_id,
                    product_id,
                    serial,
                    topology,
                } => {
                    if adapter.family != SelectorFamily::Usb {
                        return Err(ConfigError::UnsupportedSelector);
                    }
                    UsbSelector {
                        vendor_id,
                        product_id,
                        serial: serial
                            .map(|s| Serial::new(&s))
                            .transpose()
                            .map_err(|_| ConfigError::InvalidSelector)?,
                        topology: topology
                            .map(|s| Topology::new(&s))
                            .transpose()
                            .map_err(|_| ConfigError::InvalidSelector)?,
                    }
                }
            };
            let command_groups = adapter
                .command_groups
                .iter()
                .filter(|(cap, _)| allowed_capabilities.contains(*cap))
                .map(|(cap, group)| (cap.clone(), *group))
                .collect();
            let device_id = slot.device_id;
            let configured = ConfiguredSlot {
                device_id: device_id.clone(),
                enabled: slot.enabled,
                adapter_kind: slot.adapter_kind,
                allowed_capabilities,
                command_groups,
                selector,
            };
            if slots.insert(device_id, configured).is_some() {
                return Err(ConfigError::DuplicateDevice);
            }
        }
        Ok(Self { slots })
    }

    pub fn slots(&self) -> impl Iterator<Item = &ConfiguredSlot> {
        self.slots.values()
    }

    /// No discovery result activates a seed. Physical capability intersection and
    /// a sound runtime installation witness are a later composition boundary.
    pub fn core_seeds(&self, agent: &AgentInstanceId) -> Vec<CoreDeviceSeed> {
        let mut next_resource = 0_u64;
        self.slots()
            .map(|slot| {
                let mut resources = BTreeMap::new();
                let capability_resources = slot
                    .command_groups
                    .iter()
                    .map(|(cap, group)| {
                        let resource = *resources.entry(*group).or_insert_with(|| {
                            next_resource += 1;
                            ResourceId::new(next_resource)
                        });
                        (cap.clone(), resource)
                    })
                    .collect();
                CoreDeviceSeed {
                    snapshot: DeviceSnapshot {
                        agent_instance_id: agent.clone(),
                        device_id: slot.device_id.clone(),
                        binding_instance_id: None,
                        state_revision: StateRevision::new(0),
                        adapter_kind: slot.adapter_kind.clone(),
                        availability: if slot.enabled {
                            DeviceAvailability::Absent
                        } else {
                            DeviceAvailability::Disabled
                        },
                        conditions: BTreeSet::new(),
                        capabilities: BTreeSet::new(),
                    },
                    allowed_capabilities: slot.allowed_capabilities.iter().cloned().collect(),
                    capability_resources,
                }
            })
            .collect()
    }
}
