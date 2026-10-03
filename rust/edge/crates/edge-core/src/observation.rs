use std::cell::Cell;
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

use edge_adapter_api::{ObservationPoll, ObservationSource};
use edge_protocol::{
    BindingInstanceId, Capability, DeviceId, DeviceObservation, DeviceObservationEvent, EdgeEvent,
    EventSequence,
};

use super::*;
use crate::panic_boundary::{adapter_call, adapter_drop, install_privacy_hook};

/// Privileged publication handle issued only for an installed source. Cloning
/// it does not extend source lifetime or transfer binding authority.
#[derive(Clone)]
pub struct ObservationToken {
    owner: Rc<()>,
    device: DeviceId,
    binding: BindingInstanceId,
    live: Rc<Cell<bool>>,
}

impl std::fmt::Debug for ObservationToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ObservationToken").finish_non_exhaustive()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ObservationDisposition {
    Published,
    Fenced,
    CapabilityUnavailable,
}

struct InstalledSource<S> {
    token: ObservationToken,
    source: Option<S>,
}

impl<S> Drop for InstalledSource<S> {
    fn drop(&mut self) {
        self.token.live.set(false);
        if let Some(source) = self.source.take() {
            adapter_drop(source);
        }
    }
}

/// Synchronous, bounded one-poll-per-source drives in logical-device order.
/// Core alone supplies identity, revision and the global sequence. Destroying a
/// live supervisor abandons the epoch; it is not a substitute for invalidation.
pub struct ObservationSupervisor<S: ObservationSource> {
    sources: BTreeMap<DeviceId, InstalledSource<S>>,
    owner: Option<Rc<()>>,
}

impl<S: ObservationSource> Default for ObservationSupervisor<S> {
    fn default() -> Self {
        Self::new()
    }
}

impl<S: ObservationSource> ObservationSupervisor<S> {
    pub fn new() -> Self {
        install_privacy_hook();
        Self {
            sources: BTreeMap::new(),
            owner: None,
        }
    }

    pub fn install_binding<P: CoreCommand, C: AgentClock, Q: ExecutorQueuePort<P>>(
        &mut self,
        core: &mut CoreActor<P, C, Q>,
        device: &DeviceId,
        binding: &BindingInstanceId,
        capabilities: BTreeSet<Capability>,
        source: S,
    ) -> Result<BindingInstallationWitness, LifecycleError> {
        // Guard rejected sources, too; no raw destructor panic diagnostics.
        let live = Rc::new(Cell::new(true));
        let token = ObservationToken {
            owner: Rc::clone(&core.authority),
            device: device.clone(),
            binding: binding.clone(),
            live: Rc::clone(&live),
        };
        let installed = InstalledSource {
            token,
            source: Some(source),
        };
        if self
            .owner
            .as_ref()
            .is_some_and(|owner| !core.matches_authority(owner))
        {
            return Err(LifecycleError::Fatal(
                core.stop(CoreFatalError::BindingInstallationInvariant),
            ));
        }
        let (_, expected) = core.installation_requirements(device, binding)?;
        if expected.is_empty() || expected != capabilities {
            return Err(LifecycleError::Rejected(
                LifecycleRejection::IncompleteInstallation,
            ));
        }
        if !self.sources.contains_key(device) && self.sources.len() >= core.limits.max_devices {
            return Err(LifecycleError::Rejected(
                LifecycleRejection::IncompleteInstallation,
            ));
        }
        let mut witness =
            core.installation_witness(device, binding, BTreeSet::new(), Rc::clone(&live))?;
        witness.observations = expected;
        let slot = core.devices.get_mut(device).expect("validated device");
        if let Some(previous) = slot
            .observation_installation
            .take()
            .and_then(|v| v.upgrade())
        {
            previous.set(false);
        }
        slot.observation_installation = Some(Rc::downgrade(&live));
        self.owner = Some(Rc::clone(&core.authority));
        self.sources.insert(device.clone(), installed);
        Ok(witness)
    }

    pub fn publication_token(&self, device: &DeviceId) -> Option<ObservationToken> {
        self.sources.get(device).map(|s| s.token.clone())
    }

    /// Immediately drop retired/cancelled sources without polling or I/O.
    pub fn reap<P: CoreCommand, C: AgentClock, Q: ExecutorQueuePort<P>>(
        &mut self,
        core: &mut CoreActor<P, C, Q>,
    ) -> Result<(), CoreFatalError> {
        core.ensure_live()?;
        if self
            .owner
            .as_ref()
            .is_some_and(|o| !core.matches_authority(o))
        {
            return Err(core.stop(CoreFatalError::BindingInstallationInvariant));
        }
        self.sources.retain(|_, s| {
            s.token.live.get() && !core.installation_retired(&s.token.device, &s.token.binding)
        });
        Ok(())
    }

    pub fn drive<P: CoreCommand, C: AgentClock, Q: ExecutorQueuePort<P>>(
        &mut self,
        core: &mut CoreActor<P, C, Q>,
    ) -> Result<(), CoreFatalError> {
        self.reap(core)?;
        for installed in self.sources.values_mut() {
            // Pending installations never poll before activation.
            if !core.observation_current(&installed.token) {
                continue;
            }
            let outcome =
                adapter_call(|| installed.source.as_mut().expect("installed source").poll());
            let reason = match outcome {
                Ok(ObservationPoll::Pending) => continue,
                Ok(ObservationPoll::Observation(value)) => {
                    if core.publish_observation(&installed.token, value)?
                        == ObservationDisposition::Published
                    {
                        continue;
                    }
                    BindingInvalidation::ObservationFault
                }
                Ok(ObservationPoll::BindingLost(_)) => BindingInvalidation::Disconnected,
                Ok(ObservationPoll::ContinuityLost(_)) => {
                    BindingInvalidation::ObservationContinuityLost
                }
                Err(()) => BindingInvalidation::ObservationFault,
            };
            // Stop future I/O before publishing loss. Destructor failure aborts.
            // Core invalidates the whole exact epoch, including mixed command
            // resources. The executor checks that fence before every begin/poll;
            // the composition's single owner processes no requests during Drop.
            installed.token.live.set(false);
            if let Some(source) = installed.source.take() {
                adapter_drop(source);
            }
            core.invalidate_binding(&installed.token.device, &installed.token.binding, reason)
                .map_err(|e| match e {
                    LifecycleError::Fatal(e) => e,
                    _ => core.stop(CoreFatalError::BindingInstallationInvariant),
                })?;
        }
        self.reap(core)
    }
}

impl<P: CoreCommand, C: AgentClock, Q: ExecutorQueuePort<P>> CoreActor<P, C, Q> {
    fn observation_current(&self, token: &ObservationToken) -> bool {
        Rc::ptr_eq(&token.owner, &self.authority)
            && token.live.get()
            && self
                .device_snapshot(&token.device)
                .is_some_and(|d| d.binding_instance_id.as_ref() == Some(&token.binding))
    }

    pub fn publish_observation(
        &mut self,
        token: &ObservationToken,
        observation: DeviceObservation,
    ) -> Result<ObservationDisposition, CoreFatalError> {
        self.ensure_live()?;
        if !self.observation_current(token) {
            return Ok(ObservationDisposition::Fenced);
        }
        let device = self.devices.get(&token.device).expect("current device");
        let cap = Capability::new(observation.required_capability()).expect("compiled capability");
        if device.resources.contains_key(&cap) || !device.snapshot.capabilities.contains(&cap) {
            return Ok(ObservationDisposition::CapabilityUnavailable);
        }
        let revision = device.snapshot.state_revision;
        self.observe_uptime()?;
        let sequence = self.next_event_sequence()?;
        let event = EdgeEvent::DeviceObservation(Box::new(DeviceObservationEvent {
            agent_instance_id: self.agent_instance_id.clone(),
            sequence: EventSequence::new(sequence),
            device_id: token.device.clone(),
            binding_instance_id: token.binding.clone(),
            state_revision: revision,
            observation,
        }));
        self.check_event(&event)?;
        self.publish_state_event(super::events::PreparedEvent { sequence, event });
        Ok(ObservationDisposition::Published)
    }
}
