use std::collections::{BTreeMap, BTreeSet};

use edge_protocol::{AdapterKind, Capability};

use crate::{MAX_CAPABILITIES_PER_DEVICE, MAX_DEVICES, valid_name};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SelectorFamily {
    Usb,
}

/// First-party compiled metadata, not a plugin or evidence of an installed
/// driver. Local resource groups describe serialization within one device.
#[derive(Clone, Debug)]
pub struct CompiledAdapter {
    pub(crate) kind: AdapterKind,
    pub(crate) family: SelectorFamily,
    pub(crate) capabilities: BTreeSet<Capability>,
    pub(crate) command_groups: BTreeMap<Capability, u16>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CatalogError {
    TooManyAdapters,
    InvalidName,
    InvalidCapabilities,
    InvalidCommandGroups,
    DuplicateAdapter,
}

impl std::fmt::Display for CatalogError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "compiled edge adapter catalog rejected: {self:?}")
    }
}

impl std::error::Error for CatalogError {}

impl CompiledAdapter {
    pub fn usb(
        kind: AdapterKind,
        capabilities: Vec<Capability>,
        command_groups: Vec<(Capability, u16)>,
    ) -> Result<Self, CatalogError> {
        if !valid_name(kind.as_str()) || capabilities.iter().any(|c| !valid_name(c.as_str())) {
            return Err(CatalogError::InvalidName);
        }
        if capabilities.is_empty() || capabilities.len() > MAX_CAPABILITIES_PER_DEVICE {
            return Err(CatalogError::InvalidCapabilities);
        }
        let count = capabilities.len();
        let capabilities: BTreeSet<_> = capabilities.into_iter().collect();
        if capabilities.len() != count {
            return Err(CatalogError::InvalidCapabilities);
        }
        if command_groups.len() > MAX_CAPABILITIES_PER_DEVICE {
            return Err(CatalogError::InvalidCommandGroups);
        }
        let mut groups = BTreeMap::new();
        for (cap, group) in command_groups {
            if !capabilities.contains(&cap) || groups.insert(cap, group).is_some() {
                return Err(CatalogError::InvalidCommandGroups);
            }
        }
        Ok(Self {
            kind,
            family: SelectorFamily::Usb,
            capabilities,
            command_groups: groups,
        })
    }
}

#[derive(Clone, Debug)]
pub struct AdapterCatalog(BTreeMap<AdapterKind, CompiledAdapter>);

impl AdapterCatalog {
    /// Empty is valid: M8.3.1 ships no production scanner implementation.
    pub fn new(adapters: Vec<CompiledAdapter>) -> Result<Self, CatalogError> {
        if adapters.len() > MAX_DEVICES {
            return Err(CatalogError::TooManyAdapters);
        }
        let mut catalog = BTreeMap::new();
        for adapter in adapters {
            if catalog.insert(adapter.kind.clone(), adapter).is_some() {
                return Err(CatalogError::DuplicateAdapter);
            }
        }
        Ok(Self(catalog))
    }

    pub(crate) fn get(&self, kind: &AdapterKind) -> Option<&CompiledAdapter> {
        self.0.get(kind)
    }
}
