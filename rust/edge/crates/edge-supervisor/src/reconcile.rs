use std::collections::BTreeMap;

use edge_protocol::{ConditionCode, DeviceId};

use crate::config::Configuration;
use crate::discovery::{CandidateId, DiscoverySnapshot};

/// Provisional eligibility from a non-atomic scan, never a binding witness.
/// BindingManager prepares an owned attachment, revalidates current global
/// authorization, and checks the held attachment before runtime installation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SlotDisposition {
    Disabled,
    Absent,
    Ambiguous,
    Conflict,
    Eligible(CandidateId),
}

impl SlotDisposition {
    pub fn condition(&self) -> Option<ConditionCode> {
        match self {
            Self::Ambiguous => {
                Some(ConditionCode::new("edge.discovery_ambiguous").expect("authored code"))
            }
            Self::Conflict => {
                Some(ConditionCode::new("edge.discovery_conflict").expect("authored code"))
            }
            _ => None,
        }
    }
}

pub fn reconcile(
    config: &Configuration,
    snapshot: &DiscoverySnapshot,
) -> BTreeMap<DeviceId, SlotDisposition> {
    let mut results = BTreeMap::new();
    let mut claims: BTreeMap<&CandidateId, Vec<&DeviceId>> = BTreeMap::new();
    for slot in config.slots() {
        let disposition = if !slot.enabled() {
            SlotDisposition::Disabled
        } else {
            let mut matches = snapshot
                .candidates()
                .iter()
                .filter(|candidate| slot.selector().matches(candidate));
            match (matches.next(), matches.next()) {
                (None, _) => SlotDisposition::Absent,
                (Some(candidate), None) => {
                    claims
                        .entry(&candidate.id)
                        .or_default()
                        .push(slot.device_id());
                    SlotDisposition::Eligible(candidate.id.clone())
                }
                (Some(_), Some(_)) => SlotDisposition::Ambiguous,
            }
        };
        results.insert(slot.device_id().clone(), disposition);
    }
    for owners in claims.values().filter(|owners| owners.len() > 1) {
        for owner in owners {
            results.insert((*owner).clone(), SlotDisposition::Conflict);
        }
    }
    results
}
