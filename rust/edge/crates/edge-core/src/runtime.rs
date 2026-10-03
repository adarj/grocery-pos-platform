use std::collections::BTreeSet;

use edge_adapter_api::{DeviceAdapter, ObservationSource};
use edge_protocol::{BindingInstanceId, Capability, DeviceId};

use crate::panic_boundary::{adapter_call, adapter_drop, install_privacy_hook};
use crate::{
    AgentClock, BindingInstallationWitness, BoundDeviceState, CoreActor, CoreCommand,
    ExecutorSupervisor, LifecycleError, ObservationSupervisor, QueueProducer, ResourceId,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PreparationError {
    Unavailable,
    Fault,
    Panic,
}

/// Apply the same privacy/cleanup contract to first-party runtime preparation
/// as to polling. This contains panics, never blocking or background I/O.
pub fn prepare_runtime<T>(
    prepare: impl FnOnce() -> Result<T, PreparationError>,
) -> Result<T, PreparationError> {
    install_privacy_hook();
    adapter_call(prepare).map_err(|_| PreparationError::Panic)?
}

/// Owns exact attachment handles from preparation until installed or discarded.
/// No constructor grants Core authority. All cleanup uses the fatal destructor
/// boundary, including failed revalidation and partial installation.
pub struct PreparedRuntime<A, S> {
    commands: Option<Vec<(ResourceId, A)>>,
    observations: Option<(BTreeSet<Capability>, S)>,
    pub state: BoundDeviceState,
}

impl<A, S> PreparedRuntime<A, S> {
    pub fn new(
        commands: Vec<(ResourceId, A)>,
        observations: Option<(BTreeSet<Capability>, S)>,
        state: BoundDeviceState,
    ) -> Self {
        Self {
            commands: Some(commands),
            observations,
            state,
        }
    }

    /// Read-only handle access for the compiled factory's attachment check.
    pub fn observation_source(&self) -> Option<&S> {
        self.observations.as_ref().map(|(_, source)| source)
    }
}

impl<A, S> Drop for PreparedRuntime<A, S> {
    fn drop(&mut self) {
        if let Some(commands) = self.commands.take() {
            adapter_drop(commands);
        }
        if let Some(source) = self.observations.take() {
            adapter_drop(source);
        }
    }
}

impl<A, S> std::fmt::Debug for PreparedRuntime<A, S> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PreparedRuntime").finish_non_exhaustive()
    }
}

impl<A, S: ObservationSource> PreparedRuntime<A, S> {
    pub fn install<P: CoreCommand, C: AgentClock>(
        mut self,
        core: &mut CoreActor<P, C, QueueProducer<P>>,
        executor: &mut ExecutorSupervisor<P, A>,
        observations: &mut ObservationSupervisor<S>,
        device: &DeviceId,
        binding: &BindingInstanceId,
    ) -> Result<(BindingInstallationWitness, BoundDeviceState), LifecycleError>
    where
        A: DeviceAdapter<P>,
    {
        let commands = self.commands.take().expect("prepared commands");
        let command = if commands.is_empty() {
            None
        } else {
            Some(executor.install_binding(core, device, binding, commands)?)
        };
        let observation = match self.observations.take() {
            Some((caps, source)) => {
                Some(observations.install_binding(core, device, binding, caps, source)?)
            }
            None => None,
        };
        let witness = match (command, observation) {
            (Some(a), Some(b)) => a.combine(b)?,
            (Some(a), None) | (None, Some(a)) => a,
            (None, None) => {
                return Err(LifecycleError::Rejected(
                    crate::LifecycleRejection::IncompleteInstallation,
                ));
            }
        };
        Ok((witness, self.state.clone()))
    }
}
