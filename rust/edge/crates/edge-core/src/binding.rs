use std::cell::Cell;
use std::collections::BTreeSet;
use std::rc::Rc;

use edge_protocol::{
    BindingInstanceId, Capability, ConditionCode, DeviceAvailability, DeviceId, DeviceSnapshot,
    StateRevision,
};

use super::{AgentClock, CoreActor, CoreCommand, CoreFatalError, ExecutorQueuePort, ResourceId};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BindingInvalidation {
    Disconnected,
    ExecutionFault,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BoundAvailability {
    Ready,
    Degraded,
}

/// Privileged typed current-hardware facts, constrained by the configured command
/// allowlist. The caller reports the intersection of compiled adapter support and
/// current hardware support, with authored condition codes, never raw driver text.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BoundDeviceState {
    pub availability: BoundAvailability,
    pub conditions: BTreeSet<ConditionCode>,
    pub capabilities: BTreeSet<Capability>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LifecycleChange {
    Changed,
    Unchanged,
    Stale,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LifecycleRejection {
    UnknownDevice,
    InvalidTransition,
    BindingIdUsed,
    BindingHistoryFull,
    TooManyCapabilities,
    TooManyConditions,
    CapabilityNotConfigured,
    IncompleteInstallation,
    StaleInstallation,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LifecycleError {
    Rejected(LifecycleRejection),
    Fatal(CoreFatalError),
}

impl From<CoreFatalError> for LifecycleError {
    fn from(value: CoreFatalError) -> Self {
        Self::Fatal(value)
    }
}

/// Executor-issued proof of a complete fresh adapter installation. No public
/// constructor, adapter handles, or independent "installed" flag. Replacing
/// an unactivated installation invalidates all older witnesses for its resources.
/// Dropping or rejecting this move-only witness cancels the pending installation:
/// it cannot activate, and the next executor drive discards its fresh adapters.
/// Successful activation transfers cleanup ownership to the supervisor.
/// The same witness cannot be replayed:
///
/// ```compile_fail
/// use edge_core::{AgentClock, BindingInstallationWitness, BoundDeviceState,
///     CoreActor, CoreCommand, ExecutorQueuePort};
/// fn replay<P: CoreCommand, C: AgentClock, Q: ExecutorQueuePort<P>>(
///     core: &mut CoreActor<P, C, Q>, witness: BindingInstallationWitness,
///     state: BoundDeviceState,
/// ) {
///     core.activate_binding(witness, state.clone()).unwrap();
///     core.activate_binding(witness, state).unwrap(); // witness was moved
/// }
/// ```
pub struct BindingInstallationWitness {
    pub(crate) owner: Rc<()>,
    pub(crate) device_id: DeviceId,
    pub(crate) binding: BindingInstanceId,
    pub(crate) revision: StateRevision,
    pub(crate) resources: BTreeSet<ResourceId>,
    // Installation lifetime proof only; never a second binding/execution truth.
    live: Option<Rc<Cell<bool>>>,
}

impl Drop for BindingInstallationWitness {
    fn drop(&mut self) {
        if let Some(live) = self.live.take() {
            live.set(false);
        }
    }
}

impl std::fmt::Debug for BindingInstallationWitness {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BindingInstallationWitness")
            .finish_non_exhaustive()
    }
}

impl<P: CoreCommand, C: AgentClock, Q: ExecutorQueuePort<P>> CoreActor<P, C, Q> {
    pub fn device_snapshot(&self, device: &DeviceId) -> Option<&DeviceSnapshot> {
        self.devices.get(device).map(|v| &v.snapshot)
    }

    pub(crate) fn installation_retired(
        &self,
        device: &DeviceId,
        binding: &BindingInstanceId,
    ) -> bool {
        // Unactivated fresh installations must survive the two-phase gap.
        // Previously activated installations derive retirement from current
        // public binding truth; there is no separate execution fence.
        self.binding_history.contains(binding)
            && self
                .devices
                .get(device)
                .is_none_or(|slot| slot.snapshot.binding_instance_id.as_ref() != Some(binding))
    }

    pub fn begin_connecting(
        &mut self,
        device: &DeviceId,
    ) -> Result<LifecycleChange, LifecycleError> {
        self.ensure_live()?;
        let mut next = self.lifecycle_snapshot(device)?;
        if next.binding_instance_id.is_some() || next.availability == DeviceAvailability::Disabled {
            return Err(LifecycleError::Rejected(
                LifecycleRejection::InvalidTransition,
            ));
        }
        next.availability = DeviceAvailability::Connecting;
        next.conditions.clear();
        self.commit_device_state(next).map_err(Into::into)
    }

    /// Exact-epoch invalidation is the sole removal of execution authority.
    /// A delayed report about an old binding cannot change its replacement.
    pub fn invalidate_binding(
        &mut self,
        device: &DeviceId,
        binding: &BindingInstanceId,
        reason: BindingInvalidation,
    ) -> Result<LifecycleChange, LifecycleError> {
        self.ensure_live()?;
        let mut next = self.lifecycle_snapshot(device)?;
        if next.binding_instance_id.as_ref() != Some(binding) {
            return Ok(LifecycleChange::Stale);
        }
        next.binding_instance_id = None;
        next.capabilities.clear();
        next.conditions.clear();
        next.availability = match reason {
            BindingInvalidation::Disconnected => DeviceAvailability::Absent,
            BindingInvalidation::ExecutionFault => {
                let condition = ConditionCode::new("edge.binding_invalidated").map_err(|_| {
                    LifecycleError::Fatal(self.stop(CoreFatalError::InvalidCompiledCommand))
                })?;
                next.conditions.insert(condition);
                DeviceAvailability::Faulted
            }
        };
        self.commit_device_state(next).map_err(Into::into)
    }

    pub fn update_bound_device_state(
        &mut self,
        device: &DeviceId,
        binding: &BindingInstanceId,
        state: BoundDeviceState,
    ) -> Result<LifecycleChange, LifecycleError> {
        self.ensure_live()?;
        let mut next = self.lifecycle_snapshot(device)?;
        if next.binding_instance_id.as_ref() != Some(binding) {
            return Ok(LifecycleChange::Stale);
        }
        self.validate_bound_state(device, &state)?;
        apply_bound_state(&mut next, state);
        self.commit_device_state(next).map_err(Into::into)
    }

    pub fn activate_binding(
        &mut self,
        mut witness: BindingInstallationWitness,
        state: BoundDeviceState,
    ) -> Result<LifecycleChange, LifecycleError> {
        self.ensure_live()?;
        if !Rc::ptr_eq(&witness.owner, &self.authority) {
            return Err(LifecycleError::Fatal(
                self.stop(CoreFatalError::BindingInstallationInvariant),
            ));
        }
        let mut next = self.lifecycle_snapshot(&witness.device_id)?;
        if witness.live.as_ref().is_none_or(|live| !live.get())
            || next.state_revision != witness.revision
        {
            return Err(LifecycleError::Rejected(
                LifecycleRejection::StaleInstallation,
            ));
        }
        let resources = self.installation_resources(&witness.device_id, &witness.binding)?;
        if resources != witness.resources {
            return Err(LifecycleError::Fatal(
                self.stop(CoreFatalError::BindingInstallationInvariant),
            ));
        }
        self.validate_bound_state(&witness.device_id, &state)?;
        next.binding_instance_id = Some(witness.binding.clone());
        apply_bound_state(&mut next, state);
        // Prepare/validate the event before remembering the new epoch or
        // publishing any authority. History and public state commit together.
        let (next, event) = self.prepare_device_state(next)?;
        self.binding_history.insert(witness.binding.clone());
        self.devices
            .get_mut(&witness.device_id)
            .ok_or(CoreFatalError::BindingInstallationInvariant)?
            .snapshot = next;
        self.publish_state_event(event);
        // Only a committed activation disarms pending-installation cleanup.
        // Every rejection/fatal early return cancels through witness Drop.
        witness.live.take();
        Ok(LifecycleChange::Changed)
    }

    pub(crate) fn installation_resources(
        &self,
        device: &DeviceId,
        binding: &BindingInstanceId,
    ) -> Result<BTreeSet<ResourceId>, LifecycleError> {
        self.ensure_live()?;
        let slot = self
            .devices
            .get(device)
            .ok_or(LifecycleError::Rejected(LifecycleRejection::UnknownDevice))?;
        if slot.snapshot.binding_instance_id.is_some()
            || slot.snapshot.availability != DeviceAvailability::Connecting
        {
            return Err(LifecycleError::Rejected(
                LifecycleRejection::InvalidTransition,
            ));
        }
        // This checkpoint models command-resource adapters. An empty install
        // cannot witness a physical attachment; disabled/unconfigured execution
        // slots may remain unbound. Observation-only attachment is not modeled.
        if slot.resources.is_empty() {
            return Err(LifecycleError::Rejected(
                LifecycleRejection::IncompleteInstallation,
            ));
        }
        if self.binding_history.contains(binding) {
            return Err(LifecycleError::Rejected(LifecycleRejection::BindingIdUsed));
        }
        if self.binding_history.len() >= self.limits.max_binding_epochs_per_agent {
            return Err(LifecycleError::Rejected(
                LifecycleRejection::BindingHistoryFull,
            ));
        }
        Ok(slot.resources.values().copied().collect())
    }

    pub(crate) fn installation_witness(
        &self,
        device: &DeviceId,
        binding: &BindingInstanceId,
        resources: BTreeSet<ResourceId>,
        live: Rc<Cell<bool>>,
    ) -> Result<BindingInstallationWitness, CoreFatalError> {
        let revision = self
            .devices
            .get(device)
            .ok_or(CoreFatalError::BindingInstallationInvariant)?
            .snapshot
            .state_revision;
        Ok(BindingInstallationWitness {
            owner: Rc::clone(&self.authority),
            device_id: device.clone(),
            binding: binding.clone(),
            revision,
            resources,
            live: Some(live),
        })
    }

    fn lifecycle_snapshot(&self, device: &DeviceId) -> Result<DeviceSnapshot, LifecycleError> {
        self.devices
            .get(device)
            .map(|v| v.snapshot.clone())
            .ok_or(LifecycleError::Rejected(LifecycleRejection::UnknownDevice))
    }

    fn validate_bound_state(
        &self,
        device: &DeviceId,
        state: &BoundDeviceState,
    ) -> Result<(), LifecycleError> {
        if state.capabilities.len() > self.limits.max_capabilities_per_device {
            return Err(LifecycleError::Rejected(
                LifecycleRejection::TooManyCapabilities,
            ));
        }
        if state.conditions.len() > self.limits.max_conditions_per_device {
            return Err(LifecycleError::Rejected(
                LifecycleRejection::TooManyConditions,
            ));
        }
        let slot = self
            .devices
            .get(device)
            .ok_or(LifecycleError::Rejected(LifecycleRejection::UnknownDevice))?;
        if state
            .capabilities
            .iter()
            .any(|cap| !slot.allowed_capabilities.contains(cap))
        {
            return Err(LifecycleError::Rejected(
                LifecycleRejection::CapabilityNotConfigured,
            ));
        }
        Ok(())
    }

    fn prepare_device_state(
        &mut self,
        mut next: DeviceSnapshot,
    ) -> Result<(DeviceSnapshot, super::events::PreparedEvent), CoreFatalError> {
        self.observe_uptime()?;
        let result = next
            .state_revision
            .get()
            .checked_add(1)
            .ok_or(CoreFatalError::StateRevisionOverflow);
        next.state_revision = StateRevision::new(self.latch(result)?);
        let event = self.prepare_device_event(next.clone())?;
        Ok((next, event))
    }

    fn commit_device_state(
        &mut self,
        next: DeviceSnapshot,
    ) -> Result<LifecycleChange, CoreFatalError> {
        if self
            .devices
            .get(&next.device_id)
            .is_some_and(|v| v.snapshot == next)
        {
            return Ok(LifecycleChange::Unchanged);
        }
        let (next, event) = self.prepare_device_state(next)?;
        let device = self
            .devices
            .get_mut(&next.device_id)
            .ok_or(CoreFatalError::BindingInstallationInvariant)?;
        device.snapshot = next;
        self.publish_state_event(event);
        Ok(LifecycleChange::Changed)
    }
}

fn apply_bound_state(snapshot: &mut DeviceSnapshot, state: BoundDeviceState) {
    snapshot.availability = match state.availability {
        BoundAvailability::Ready => DeviceAvailability::Ready,
        BoundAvailability::Degraded => DeviceAvailability::Degraded,
    };
    snapshot.conditions = state.conditions;
    snapshot.capabilities = state.capabilities;
}
