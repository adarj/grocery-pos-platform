//! Privileged repeatable composition. Scan eligibility is never runtime proof.
use std::collections::{BTreeMap, BTreeSet};

use edge_adapter_api::{DeviceAdapter, ObservationSource};
use edge_core::{
    AgentClock, BindingInvalidation, CoreActor, CoreCommand, ExecutorSupervisor, LifecycleError,
    ObservationSupervisor, PreparationError, PreparedRuntime, QueueProducer, ResourceId,
    prepare_runtime,
};
use edge_protocol::{
    AdapterKind, BindingInstanceId, Capability, ConditionCode, DeviceAvailability, DeviceId,
};

use crate::catalog::AdapterCatalog;

use crate::config::{Configuration, ConfiguredSlot};
use crate::discovery::{DiscoveryCandidate, DiscoveryError, DiscoverySnapshot, DiscoverySource};
use crate::reconcile::{SlotDisposition, reconcile};

/// First-party compiled factory registry, never configuration-loaded code. A
/// successful preparation owns the exact attachment. It must not migrate to a
/// replacement, even when sysfs identity is reused. check_attachment verifies
/// that held handle against fresh facts, without releasing ownership. Real
/// drivers must prove this contract with Linux handles; synthetic tests only
/// establish composition here. All calls and cleanup must be bounded/private.
pub trait RuntimeFactory<P: CoreCommand> {
    type CommandAdapter: DeviceAdapter<P>;
    type Observations: ObservationSource;

    fn prepare(
        &mut self,
        slot: &ConfiguredSlot,
        candidate: &DiscoveryCandidate,
        resources: &[(Capability, ResourceId)],
    ) -> Result<PreparedRuntime<Self::CommandAdapter, Self::Observations>, PreparationError>;

    fn check_attachment(
        &mut self,
        slot: &ConfiguredSlot,
        prepared: &PreparedRuntime<Self::CommandAdapter, Self::Observations>,
        candidate: &DiscoveryCandidate,
    ) -> Result<(), PreparationError>;
}

type CompiledFactory<P, A, S> = Box<dyn RuntimeFactory<P, CommandAdapter = A, Observations = S>>;

/// Bounded startup registry of compiled first-party factories. Boxed dispatch
/// does not load code: no filename, shared object or configuration plugin exists.
/// Metadata alone does not make a kind operational; a matching factory is needed.
pub struct RuntimeFactoryRegistry<P: CoreCommand, A: DeviceAdapter<P>, S: ObservationSource> {
    factories: BTreeMap<AdapterKind, CompiledFactory<P, A, S>>,
}

impl<P: CoreCommand, A: DeviceAdapter<P>, S: ObservationSource> RuntimeFactoryRegistry<P, A, S> {
    pub fn new(
        catalog: &AdapterCatalog,
        factories: impl IntoIterator<Item = (AdapterKind, CompiledFactory<P, A, S>)>,
    ) -> Result<Self, PreparationError> {
        let mut entries = BTreeMap::new();
        for (kind, factory) in factories {
            if entries.len() >= crate::MAX_DEVICES
                || catalog.get(&kind).is_none()
                || entries.contains_key(&kind)
            {
                return Err(PreparationError::Fault);
            }
            entries.insert(kind, factory);
        }
        Ok(Self { factories: entries })
    }
}

impl<P: CoreCommand, A: DeviceAdapter<P>, S: ObservationSource> RuntimeFactory<P>
    for RuntimeFactoryRegistry<P, A, S>
{
    type CommandAdapter = A;
    type Observations = S;

    fn prepare(
        &mut self,
        slot: &ConfiguredSlot,
        candidate: &DiscoveryCandidate,
        resources: &[(Capability, ResourceId)],
    ) -> Result<PreparedRuntime<A, S>, PreparationError> {
        self.factories
            .get_mut(slot.adapter_kind())
            .ok_or(PreparationError::Unavailable)?
            .prepare(slot, candidate, resources)
    }

    fn check_attachment(
        &mut self,
        slot: &ConfiguredSlot,
        prepared: &PreparedRuntime<A, S>,
        candidate: &DiscoveryCandidate,
    ) -> Result<(), PreparationError> {
        self.factories
            .get_mut(slot.adapter_kind())
            .ok_or(PreparationError::Unavailable)?
            .check_attachment(slot, prepared, candidate)
    }
}

/// Production composition must supply unpredictable, fresh opaque IDs. No
/// weak generator or candidate-derived default is provided in this checkpoint.
pub trait BindingIdSource {
    fn next_id(&mut self) -> Result<BindingInstanceId, PreparationError>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BindingError {
    Discovery(DiscoveryError),
    Preparation(PreparationError),
    Lifecycle(LifecycleError),
}

impl From<LifecycleError> for BindingError {
    fn from(e: LifecycleError) -> Self {
        Self::Lifecycle(e)
    }
}

struct ActiveAttachment {
    candidate: DiscoveryCandidate,
    binding: BindingInstanceId,
}

pub struct BindingManager<D, F, I> {
    config: Configuration,
    discovery: D,
    factory: F,
    ids: I,
    active: BTreeMap<DeviceId, ActiveAttachment>,
}

impl<D: DiscoverySource, F, I: BindingIdSource> BindingManager<D, F, I> {
    pub fn new(config: Configuration, discovery: D, factory: F, ids: I) -> Self {
        Self {
            config,
            discovery,
            factory,
            ids,
            active: BTreeMap::new(),
        }
    }

    pub fn reconcile<P: CoreCommand, C: AgentClock>(
        &mut self,
        core: &mut CoreActor<P, C, QueueProducer<P>>,
        executor: &mut ExecutorSupervisor<P, F::CommandAdapter>,
        observations: &mut ObservationSupervisor<F::Observations>,
    ) -> Result<(), BindingError>
    where
        F: RuntimeFactory<P>,
    {
        // Any failed complete scan withdraws existing attachment authority.
        let mut snapshot = match self.discovery.snapshot() {
            Ok(s) => s,
            Err(e) => {
                self.retire_all(core, executor, observations)?;
                return Err(BindingError::Discovery(e));
            }
        };
        self.retire_unauthorized(core, executor, observations, &snapshot)?;
        let mut dispositions = reconcile(&self.config, &snapshot);
        let seeds = self.config.core_seeds(core.agent_instance_id());
        // Clone the bounded configuration list to permit subsequent full scans.
        let slots: Vec<_> = self.config.slots().cloned().collect();
        for slot in slots {
            let device = slot.device_id();
            if self.active.contains_key(device) {
                continue;
            }
            let disposition = dispositions[device].clone();
            let SlotDisposition::Eligible(ref id) = disposition else {
                apply_unbound(core, device, &disposition)?;
                continue;
            };
            let candidate = snapshot
                .candidates()
                .iter()
                .find(|c| &c.id == id)
                .expect("reconciled candidate")
                .clone();
            core.begin_connecting(device)?;
            let resources = &seeds
                .iter()
                .find(|s| &s.snapshot.device_id == device)
                .expect("configured seed")
                .capability_resources;
            let prepared =
                match prepare_runtime(|| self.factory.prepare(&slot, &candidate, resources)) {
                    Ok(r) => r,
                    Err(e) => {
                        preparation_fault(core, device)?;
                        return Err(BindingError::Preparation(e));
                    }
                };
            // Prepared ownership protects the non-atomic scan-to-activate gap.
            let fresh = match self.discovery.snapshot() {
                Ok(s) => s,
                Err(e) => {
                    drop(prepared);
                    self.retire_all(core, executor, observations)?;
                    preparation_fault(core, device)?;
                    return Err(BindingError::Discovery(e));
                }
            };
            self.retire_unauthorized(core, executor, observations, &fresh)?;
            let current = reconcile(&self.config, &fresh);
            let same = current.get(device)
                == Some(&SlotDisposition::Eligible(candidate.id.clone()))
                && fresh.candidates().iter().any(|c| c == &candidate);
            snapshot = fresh;
            dispositions = current.clone();
            if !same {
                drop(prepared);
                match &current[device] {
                    SlotDisposition::Eligible(_) => {
                        preparation_fault(core, device)?;
                    }
                    other => {
                        apply_unbound(core, device, other)?;
                    }
                }
                continue;
            }
            if let Err(e) =
                prepare_runtime(|| self.factory.check_attachment(&slot, &prepared, &candidate))
            {
                drop(prepared);
                preparation_fault(core, device)?;
                return Err(BindingError::Preparation(e));
            }
            let binding = match self.ids.next_id() {
                Ok(id) => id,
                Err(e) => {
                    drop(prepared);
                    preparation_fault(core, device)?;
                    return Err(BindingError::Preparation(e));
                }
            };
            let activation = prepared
                .install(core, executor, observations, device, &binding)
                .and_then(|(proof, state)| core.activate_binding(proof, state));
            if let Err(e) = activation {
                if matches!(e, LifecycleError::Rejected(_)) {
                    preparation_fault(core, device)?;
                    observations
                        .reap(core)
                        .map_err(|e| BindingError::Lifecycle(LifecycleError::Fatal(e)))?;
                    executor
                        .drive(core)
                        .map_err(|e| BindingError::Lifecycle(LifecycleError::Fatal(e)))?;
                }
                return Err(e.into());
            }
            self.active.insert(
                device.clone(),
                ActiveAttachment {
                    candidate: candidate.clone(),
                    binding,
                },
            );
        }
        Ok(())
    }

    fn retire_all<P: CoreCommand, C: AgentClock>(
        &mut self,
        core: &mut CoreActor<P, C, QueueProducer<P>>,
        executor: &mut ExecutorSupervisor<P, F::CommandAdapter>,
        observations: &mut ObservationSupervisor<F::Observations>,
    ) -> Result<(), BindingError>
    where
        F: RuntimeFactory<P>,
    {
        for (device, active) in std::mem::take(&mut self.active) {
            core.invalidate_binding(
                &device,
                &active.binding,
                BindingInvalidation::DiscoveryFault,
            )?;
        }
        observations
            .reap(core)
            .map_err(|e| BindingError::Lifecycle(LifecycleError::Fatal(e)))?;
        executor
            .drive(core)
            .map_err(|e| BindingError::Lifecycle(LifecycleError::Fatal(e)))?;
        Ok(())
    }

    fn retire_unauthorized<P: CoreCommand, C: AgentClock>(
        &mut self,
        core: &mut CoreActor<P, C, QueueProducer<P>>,
        executor: &mut ExecutorSupervisor<P, F::CommandAdapter>,
        observations: &mut ObservationSupervisor<F::Observations>,
        snapshot: &DiscoverySnapshot,
    ) -> Result<(), BindingError>
    where
        F: RuntimeFactory<P>,
    {
        let results = reconcile(&self.config, snapshot);
        let mut retired = Vec::new();
        for (device, active) in &self.active {
            let still_current = core
                .device_snapshot(device)
                .is_some_and(|s| s.binding_instance_id.as_ref() == Some(&active.binding));
            let authorized = results.get(device)
                == Some(&SlotDisposition::Eligible(active.candidate.id.clone()))
                && snapshot.candidates().contains(&active.candidate);
            if !still_current || !authorized {
                core.invalidate_binding(
                    device,
                    &active.binding,
                    BindingInvalidation::Disconnected,
                )?;
                retired.push(device.clone());
            }
        }
        for device in retired {
            self.active.remove(&device);
        }
        observations
            .reap(core)
            .map_err(|e| BindingError::Lifecycle(LifecycleError::Fatal(e)))?;
        executor
            .drive(core)
            .map_err(|e| BindingError::Lifecycle(LifecycleError::Fatal(e)))?;
        Ok(())
    }
}

fn apply_unbound<P: CoreCommand, C: AgentClock>(
    core: &mut CoreActor<P, C, QueueProducer<P>>,
    device: &DeviceId,
    disposition: &SlotDisposition,
) -> Result<(), LifecycleError> {
    core.update_unbound_state(
        device,
        match disposition {
            SlotDisposition::Disabled => DeviceAvailability::Disabled,
            SlotDisposition::Absent => DeviceAvailability::Absent,
            _ => DeviceAvailability::Faulted,
        },
        disposition.condition().into_iter().collect(),
    )
    .map(|_| ())
}

fn preparation_fault<P: CoreCommand, C: AgentClock>(
    core: &mut CoreActor<P, C, QueueProducer<P>>,
    device: &DeviceId,
) -> Result<(), LifecycleError> {
    core.update_unbound_state(
        device,
        DeviceAvailability::Faulted,
        BTreeSet::from([
            ConditionCode::new("edge.binding_preparation_failed").expect("authored condition")
        ]),
    )
    .map(|_| ())
}
