use std::collections::{BTreeMap, BTreeSet, btree_map::Entry};
use std::fmt;
use std::rc::Rc;
use std::sync::Arc;

use edge_protocol::{
    AgentInstanceId, AgentUptimeMs, BindingInstanceId, Capability, CommandId, CommandKind,
    CommandState, CommandSubmission, CommandTimeoutMs, DeviceId, DeviceSnapshot, ErrorCode,
    NonterminalCommandState, ProtocolError, TerminalCommandState,
};

use crate::model::{
    AdmissionDecision, AdmissionRejection, AgentClock, CoreCommand, CoreDeviceSeed, CoreFatalError,
    CoreLimits, ResourceId,
};
use crate::queue::{ExecutorQueuePort, QueueCommitError, QueueReservationError, QueuedCommand};

#[path = "binding.rs"]
mod binding;
#[path = "events.rs"]
mod events;

pub use binding::{
    BindingInstallationWitness, BindingInvalidation, BoundAvailability, BoundDeviceState,
    LifecycleChange, LifecycleError, LifecycleRejection,
};
pub use events::{EventPoll, EventSubscription, SubscriptionError, SubscriptionToken};

struct CoreDevice {
    snapshot: DeviceSnapshot,
    resources: BTreeMap<Capability, ResourceId>,
}

// Command ID is the map key; request ID and agent precondition are deliberately
// absent. No raw JSON or full payload is needed after terminal compaction.
#[derive(Clone, Eq, PartialEq)]
struct RetainedIdentity<F> {
    device_id: DeviceId,
    binding_instance_id: BindingInstanceId,
    not_after_agent_uptime_ms: AgentUptimeMs,
    kind: CommandKind,
    timeout_ms: CommandTimeoutMs,
    payload_fingerprint: F,
}

impl<F> RetainedIdentity<F> {
    fn from_submission<P: CoreCommand<PayloadFingerprint = F>>(
        submission: &CommandSubmission<P>,
    ) -> Self {
        Self {
            device_id: submission.device_id.clone(),
            binding_instance_id: submission.expected_binding_instance_id.clone(),
            not_after_agent_uptime_ms: submission.not_after_agent_uptime_ms,
            kind: submission.kind.clone(),
            timeout_ms: submission.timeout_ms,
            payload_fingerprint: submission.payload.retained_payload_fingerprint(),
        }
    }
}

enum CommandRecord<P: CoreCommand> {
    Active {
        state: NonterminalCommandState,
        _payload: Arc<P>,
        executing: bool,
        identity: RetainedIdentity<P::PayloadFingerprint>,
        admission_sequence: u64,
    },
    Terminal {
        state: TerminalCommandState,
        identity: RetainedIdentity<P::PayloadFingerprint>,
        admission_sequence: u64,
    },
}

impl<P: CoreCommand> CommandRecord<P> {
    fn identity(&self) -> &RetainedIdentity<P::PayloadFingerprint> {
        match self {
            Self::Active { identity, .. } | Self::Terminal { identity, .. } => identity,
        }
    }

    fn public_state(&self) -> CommandState {
        match self {
            Self::Active {
                state, executing, ..
            } => {
                if *executing {
                    CommandState::Executing(state.clone())
                } else {
                    CommandState::Accepted(state.clone())
                }
            }
            Self::Terminal { state, .. } => CommandState::Terminal(state.clone()),
        }
    }
}

/// One exclusive owner of admission truth. A later daemon may run this value
/// inside one task; this actor has no locks, scheduling tasks, or device I/O.
pub struct CoreActor<P, C, Q>
where
    P: CoreCommand,
    C: AgentClock,
    Q: ExecutorQueuePort<P>,
{
    agent_instance_id: AgentInstanceId,
    limits: CoreLimits,
    clock: C,
    last_observed_uptime: Option<AgentUptimeMs>,
    devices: BTreeMap<DeviceId, CoreDevice>,
    records: BTreeMap<CommandId, CommandRecord<P>>,
    next_admission_sequence: u64,
    queue: Q,
    authority: Rc<()>,
    binding_history: BTreeSet<BindingInstanceId>,
    events: events::EventState,
    fatal: Option<CoreFatalError>,
}

impl<P, C, Q> fmt::Debug for CoreActor<P, C, Q>
where
    P: CoreCommand,
    C: AgentClock,
    Q: ExecutorQueuePort<P>,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CoreActor")
            .field("agent_instance_id", &self.agent_instance_id)
            .field("device_count", &self.devices.len())
            .field("retained_command_count", &self.records.len())
            .finish_non_exhaustive()
    }
}

impl<P, C, Q> CoreActor<P, C, Q>
where
    P: CoreCommand,
    C: AgentClock,
    Q: ExecutorQueuePort<P>,
{
    pub fn new(
        agent_instance_id: AgentInstanceId,
        seeds: Vec<CoreDeviceSeed>,
        limits: CoreLimits,
        clock: C,
        queue: Q,
    ) -> Result<Self, CoreFatalError> {
        if limits.max_devices == 0
            || limits.max_resources == 0
            || limits.max_capabilities_per_device == 0
            || limits.max_conditions_per_device == 0
            || limits.max_command_records == 0
            || limits.max_command_timeout_ms == 0
            || limits.max_binding_epochs_per_agent == 0
            || limits.max_event_queue_records == 0
            || limits.max_event_record_bytes == 0
        {
            return Err(CoreFatalError::InvalidLimits);
        }
        if seeds.len() > limits.max_devices {
            return Err(CoreFatalError::TooManyDevices);
        }
        let mut devices = BTreeMap::new();
        let mut resource_owners = BTreeMap::new();
        for seed in seeds {
            let snapshot = seed.snapshot;
            if snapshot.agent_instance_id != agent_instance_id {
                return Err(CoreFatalError::RegistryAgentMismatch);
            }
            if devices.contains_key(&snapshot.device_id) {
                return Err(CoreFatalError::DuplicateDevice);
            }
            if snapshot.capabilities.len() > limits.max_capabilities_per_device {
                return Err(CoreFatalError::TooManyCapabilities);
            }
            if snapshot.conditions.len() > limits.max_conditions_per_device {
                return Err(CoreFatalError::TooManyConditions);
            }
            if seed.capability_resources.len() > limits.max_capabilities_per_device {
                return Err(CoreFatalError::TooManyCapabilities);
            }
            let mut resources = BTreeMap::new();
            for (capability, resource) in seed.capability_resources {
                if resources.insert(capability, resource).is_some() {
                    return Err(CoreFatalError::DuplicateResourceMapping);
                }
                match resource_owners.entry(resource) {
                    Entry::Vacant(entry) => {
                        entry.insert(snapshot.device_id.clone());
                    }
                    Entry::Occupied(entry) if entry.get() != &snapshot.device_id => {
                        return Err(CoreFatalError::ResourceSharedAcrossDevices);
                    }
                    Entry::Occupied(_) => {}
                }
                if resource_owners.len() > limits.max_resources {
                    return Err(CoreFatalError::TooManyResources);
                }
            }
            if resources.len() > limits.max_capabilities_per_device {
                return Err(CoreFatalError::TooManyCapabilities);
            }
            if snapshot.binding_instance_id.is_some()
                || !snapshot.capabilities.is_empty()
                || snapshot.state_revision.get() != 0
                || matches!(
                    snapshot.availability,
                    edge_protocol::DeviceAvailability::Ready
                        | edge_protocol::DeviceAvailability::Degraded
                )
            {
                return Err(CoreFatalError::InvalidInitialDeviceState);
            }
            devices.insert(
                snapshot.device_id.clone(),
                CoreDevice {
                    snapshot,
                    resources,
                },
            );
        }
        Ok(Self {
            agent_instance_id,
            limits,
            clock,
            last_observed_uptime: None,
            devices,
            records: BTreeMap::new(),
            next_admission_sequence: 0,
            queue,
            authority: Rc::new(()),
            binding_history: BTreeSet::new(),
            events: events::EventState::default(),
            fatal: None,
        })
    }

    pub fn agent_instance_id(&self) -> &AgentInstanceId {
        &self.agent_instance_id
    }

    pub fn retained_command_count(&self) -> usize {
        self.records.len()
    }

    /// Absence after safe eviction is not evidence that no physical effect
    /// occurred. This lookup does not run admission or sample the clock.
    pub fn command_status(&self, command_id: &CommandId) -> Option<CommandState> {
        self.records
            .get(command_id)
            .map(CommandRecord::public_state)
    }

    /// Preserve the normative ordering. A retained command is resolved before
    /// any freshness, device, binding, capability, cache, or queue revalidation.
    pub fn submit_command(
        &mut self,
        submission: CommandSubmission<P>,
    ) -> Result<AdmissionDecision, CoreFatalError> {
        self.ensure_live()?;
        let result = self.submit_inner(submission);
        self.latch(result)
    }

    fn submit_inner(
        &mut self,
        submission: CommandSubmission<P>,
    ) -> Result<AdmissionDecision, CoreFatalError> {
        // 1. Agent epoch, before command-ID lookup.
        if submission.expected_agent_instance_id != self.agent_instance_id {
            return Ok(AdmissionDecision::Rejected(
                AdmissionRejection::AgentInstanceConflict,
            ));
        }
        // M8.2.2 already binds kind and typed payload. Fail fatally if a first-
        // party caller constructs or mutates an inconsistent generic DTO.
        if submission.kind.as_str() != submission.payload.command_kind() {
            return Err(CoreFatalError::InvalidCompiledCommand);
        }
        // Observe the control-plane clock invariant even for retained retries.
        // This does not apply freshness or reclamation before retained lookup.
        self.observe_uptime()?;
        let identity = RetainedIdentity::from_submission(&submission);
        // 2. Retained identity, before current-state checks.
        if let Some(existing) = self.records.get(&submission.command_id) {
            return Ok(if existing.identity() == &identity {
                AdmissionDecision::Deduplicated(existing.public_state())
            } else {
                AdmissionDecision::Rejected(AdmissionRejection::SemanticConflict)
            });
        }

        // A new submission gets a current freshness sample after identity
        // formation/lookup; retained retries never reach this policy check.
        let now = self.observe_uptime()?;
        let uptime = now.get();
        let deadline = submission.not_after_agent_uptime_ms.get();
        // 3. Freshness and future horizon, using subtraction only after order.
        if uptime > deadline {
            return Ok(AdmissionDecision::Rejected(
                AdmissionRejection::SubmissionExpired,
            ));
        }
        if deadline - uptime > self.limits.max_submission_horizon_ms {
            return Ok(AdmissionDecision::Rejected(
                AdmissionRejection::SubmissionHorizonExceeded,
            ));
        }
        // 4. Acceptance-relative timeout policy, independent of freshness.
        if submission.timeout_ms.get() > self.limits.max_command_timeout_ms {
            return Ok(AdmissionDecision::Rejected(
                AdmissionRejection::TimeoutTooLarge,
            ));
        }
        // 5–7. Configured device, exact binding, compiled published capability,
        // and its internal serialized physical resource.
        let Some(device) = self.devices.get(&submission.device_id) else {
            return Ok(AdmissionDecision::Rejected(
                AdmissionRejection::UnknownDevice,
            ));
        };
        if device.snapshot.binding_instance_id.as_ref()
            != Some(&submission.expected_binding_instance_id)
        {
            return Ok(AdmissionDecision::Rejected(
                AdmissionRejection::BindingInstanceConflict,
            ));
        }
        let capability = Capability::new(submission.payload.required_capability())
            .map_err(|_| CoreFatalError::InvalidCompiledCommand)?;
        if !device.snapshot.capabilities.contains(&capability) {
            return Ok(AdmissionDecision::Rejected(
                AdmissionRejection::CapabilityUnavailable,
            ));
        }
        let Some(&resource) = device.resources.get(&capability) else {
            return Err(CoreFatalError::MissingResourceMapping);
        };
        // 8–9. Reclaim only safe terminal identities, then enforce the bound.
        self.reclaim_for_admission(now)?;
        if self.records.len() >= self.limits.max_command_records {
            return Ok(AdmissionDecision::Rejected(
                AdmissionRejection::CommandCacheFull,
            ));
        }
        // 10. A reserved slot is invisible to future execution.
        let reservation = match self.queue.reserve(&resource) {
            Ok(reservation) => reservation,
            Err(QueueReservationError::Full) => {
                return Ok(AdmissionDecision::Rejected(
                    AdmissionRejection::ExecutorQueueFull,
                ));
            }
            Err(QueueReservationError::Unavailable) => {
                return Ok(AdmissionDecision::Rejected(
                    AdmissionRejection::ExecutorUnavailable,
                ));
            }
        };
        let sequence = self
            .next_admission_sequence
            .checked_add(1)
            .ok_or(CoreFatalError::RecordSequenceOverflow)?;
        let command_id = submission.command_id.clone();
        let state = NonterminalCommandState {
            agent_instance_id: self.agent_instance_id.clone(),
            command_id: command_id.clone(),
            device_id: submission.device_id,
            binding_instance_id: submission.expected_binding_instance_id,
            kind: submission.kind,
            accepted_agent_uptime_ms: now,
        };
        let event = self.prepare_command_event(CommandState::Accepted(state.clone()))?;
        let payload = Arc::new(submission.payload);
        let queued = QueuedCommand::new(
            resource,
            &state,
            submission.timeout_ms,
            Arc::clone(&payload),
        );
        // 11. The record exists before commit can make the queued command visible.
        match self.records.entry(command_id.clone()) {
            Entry::Vacant(entry) => {
                entry.insert(CommandRecord::Active {
                    state,
                    _payload: payload,
                    executing: false,
                    identity,
                    admission_sequence: sequence,
                });
            }
            Entry::Occupied(_) => return Err(CoreFatalError::RecordInvariant),
        }
        self.next_admission_sequence = sequence;
        self.publish_state_event(event);
        let recorded = match self.records.get(&command_id) {
            Some(CommandRecord::Active { state, .. }) => state,
            _ => return Err(CoreFatalError::RecordInvariant),
        };
        // 12. The queue sees a borrowed witness from the live Core record.
        match self.queue.commit(reservation, queued, recorded) {
            Ok(()) => Ok(AdmissionDecision::Accepted(CommandState::Accepted(
                recorded.clone(),
            ))),
            Err(QueueCommitError::GuaranteedNotEnqueued) => {
                // The port guarantees the command was never visible. Preserve
                // accepted identity and report a known non-effect, not a retry.
                let terminal_at = self.observe_uptime()?;
                let terminal = self.terminalize_non_effect(&command_id, terminal_at)?;
                Ok(AdmissionDecision::Accepted(terminal))
            }
        }
    }

    pub(crate) fn observe_uptime(&mut self) -> Result<AgentUptimeMs, CoreFatalError> {
        self.ensure_live()?;
        let now = self.clock.now();
        if self.last_observed_uptime.is_some_and(|last| now < last) {
            return self.latch(Err(CoreFatalError::ClockRegression));
        }
        self.last_observed_uptime = Some(now);
        Ok(now)
    }

    fn reclaim_for_admission(&mut self, now: AgentUptimeMs) -> Result<(), CoreFatalError> {
        if self.records.len() < self.limits.max_command_records {
            return Ok(());
        }
        let mut oldest: Option<(u64, CommandId)> = None;
        for (command_id, record) in &self.records {
            if let CommandRecord::Terminal {
                state,
                identity,
                admission_sequence,
            } = record
            {
                let age = now
                    .get()
                    .checked_sub(state.terminal_agent_uptime_ms.get())
                    .ok_or(CoreFatalError::RecordInvariant)?;
                if now > identity.not_after_agent_uptime_ms
                    && age >= self.limits.terminal_recovery_minimum_ms
                    && oldest
                        .as_ref()
                        .is_none_or(|(sequence, _)| admission_sequence < sequence)
                {
                    oldest = Some((*admission_sequence, command_id.clone()));
                }
            }
        }
        if let Some((_, command_id)) = oldest {
            self.records.remove(&command_id);
        }
        Ok(())
    }

    // Narrow Core-owned transition used for the guaranteed non-enqueue failure.
    // Reuses the validated Core terminal-result machinery.
    fn terminalize_non_effect(
        &mut self,
        command_id: &CommandId,
        terminal_at: AgentUptimeMs,
    ) -> Result<CommandState, CoreFatalError> {
        self.finish_record(
            command_id,
            terminal_at,
            crate::effect::Completion::FailedNone,
            Some("edge.queue_commit_not_enqueued"),
        )
    }

    pub(crate) fn binding_executable(&self, command: &QueuedCommand<P>) -> bool {
        self.fatal.is_none()
            && self.devices.get(command.device_id()).is_some_and(|device| {
                device.snapshot.binding_instance_id.as_ref() == Some(command.binding_instance_id())
                    && device
                        .resources
                        .values()
                        .any(|resource| *resource == command.resource())
            })
    }

    pub(crate) fn ensure_live(&self) -> Result<(), CoreFatalError> {
        self.fatal.map_or(Ok(()), Err)
    }

    pub(crate) fn stop(&mut self, error: CoreFatalError) -> CoreFatalError {
        self.fatal = Some(error);
        self.events.close();
        error
    }

    pub(crate) fn matches_authority(&self, owner: &Rc<()>) -> bool {
        Rc::ptr_eq(owner, &self.authority)
    }

    pub(crate) fn latch<T>(
        &mut self,
        result: Result<T, CoreFatalError>,
    ) -> Result<T, CoreFatalError> {
        if let Err(error) = result {
            self.stop(error);
        }
        result
    }

    pub(crate) fn execution_witness(
        &self,
        command: &QueuedCommand<P>,
        executing: bool,
    ) -> Result<&NonterminalCommandState, CoreFatalError> {
        match self.records.get(command.command_id()) {
            Some(CommandRecord::Active {
                state,
                _payload,
                executing: phase,
                identity,
                ..
            }) if *phase == executing
                && command.owns_payload(_payload)
                && state.device_id == *command.device_id()
                && state.binding_instance_id == *command.binding_instance_id()
                && state.kind == *command.kind()
                && state.accepted_agent_uptime_ms == command.accepted_agent_uptime_ms()
                && identity.timeout_ms == command.timeout_ms() =>
            {
                Ok(state)
            }
            _ => Err(CoreFatalError::ExecutionInvariant),
        }
    }

    pub(crate) fn start_execution(
        &mut self,
        command: &QueuedCommand<P>,
    ) -> Result<(), CoreFatalError> {
        self.ensure_live()?;
        let result = self.start_execution_inner(command);
        self.latch(result)
    }

    fn start_execution_inner(&mut self, command: &QueuedCommand<P>) -> Result<(), CoreFatalError> {
        let state = self.execution_witness(command, false)?.clone();
        let event = self.prepare_command_event(CommandState::Executing(state))?;
        match self.records.get_mut(command.command_id()) {
            Some(CommandRecord::Active { executing, .. }) => {
                *executing = true;
                self.publish_state_event(event);
                Ok(())
            }
            _ => Err(CoreFatalError::ExecutionInvariant),
        }
    }

    pub(crate) fn finish_record(
        &mut self,
        command_id: &CommandId,
        terminal_at: AgentUptimeMs,
        completion: crate::effect::Completion,
        code: Option<&'static str>,
    ) -> Result<CommandState, CoreFatalError> {
        self.ensure_live()?;
        let result = self.finish_record_inner(command_id, terminal_at, completion, code);
        self.latch(result)
    }

    fn finish_record_inner(
        &mut self,
        command_id: &CommandId,
        terminal_at: AgentUptimeMs,
        completion: crate::effect::Completion,
        code: Option<&'static str>,
    ) -> Result<CommandState, CoreFatalError> {
        let error = code
            .map(|value| {
                ErrorCode::new(value).map(|code| ProtocolError {
                    code,
                    message: None,
                })
            })
            .transpose()
            .map_err(|_| CoreFatalError::InvalidCompiledCommand)?;
        let record = self
            .records
            .get(command_id)
            .ok_or(CoreFatalError::RecordInvariant)?;
        let (state, identity, admission_sequence) = match record {
            CommandRecord::Active {
                state,
                executing,
                identity,
                admission_sequence,
                ..
            } => {
                if !*executing
                    && !matches!(
                        completion,
                        crate::effect::Completion::Rejected | crate::effect::Completion::FailedNone
                    )
                {
                    return Err(CoreFatalError::ExecutionInvariant);
                }
                (state, identity, admission_sequence)
            }
            CommandRecord::Terminal { .. } => return Err(CoreFatalError::ExecutionInvariant),
        };
        if terminal_at < state.accepted_agent_uptime_ms
            || self
                .last_observed_uptime
                .is_none_or(|last| terminal_at > last)
        {
            return Err(CoreFatalError::RecordInvariant);
        }
        let (outcome, effect_evidence) = completion.public_pair();
        let terminal = TerminalCommandState {
            agent_instance_id: state.agent_instance_id.clone(),
            command_id: state.command_id.clone(),
            device_id: state.device_id.clone(),
            binding_instance_id: state.binding_instance_id.clone(),
            kind: state.kind.clone(),
            accepted_agent_uptime_ms: state.accepted_agent_uptime_ms,
            outcome,
            effect_evidence,
            error,
            terminal_agent_uptime_ms: terminal_at,
        };
        let compact = CommandRecord::Terminal {
            state: terminal.clone(),
            identity: identity.clone(),
            admission_sequence: *admission_sequence,
        };
        let event = self.prepare_command_event(CommandState::Terminal(terminal.clone()))?;
        self.records.insert(command_id.clone(), compact);
        self.publish_state_event(event);
        Ok(CommandState::Terminal(terminal))
    }
}

impl<P: CoreCommand, C: AgentClock> CoreActor<P, C, crate::QueueProducer<P>> {
    pub(crate) fn owns_consumer(&self, consumer: &crate::QueueConsumer<P>) -> bool {
        self.queue.owns_consumer(consumer)
    }
}

#[cfg(test)]
mod tests;
