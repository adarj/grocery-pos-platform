use std::collections::BTreeMap;
use std::fmt;

use edge_adapter_api::{AdapterOperation, AdapterPoll, AdapterPollContext, DeviceAdapter};
use edge_protocol::AgentUptimeMs;

use crate::effect::{Completion, EffectTracker};
use crate::panic_boundary::{adapter_call, adapter_drop, install_privacy_hook};
use crate::{
    AgentClock, CoreActor, CoreCommand, CoreFatalError, ExecutorQueuePort, QueueConsumer,
    QueuedCommand, ResourceId,
};

struct Active<P, O> {
    command: QueuedCommand<P>,
    operation: Option<O>,
    tracker: EffectTracker,
}

impl<P, O> Drop for Active<P, O> {
    fn drop(&mut self) {
        // Also covers fatal early returns after taking the active slot.
        if let Some(operation) = self.operation.take() {
            adapter_drop(operation);
        }
    }
}

struct ResourceExecutor<P, A: DeviceAdapter<P>> {
    adapter: Option<A>,
    active: Option<Active<P, A::Operation>>,
}

impl<P, A: DeviceAdapter<P>> Drop for ResourceExecutor<P, A> {
    fn drop(&mut self) {
        self.active.take();
        discard_adapter(&mut self.adapter);
    }
}

// An early seed rejection can leave the input iterator owning adapters that
// were never inserted into a ResourceExecutor. Their cleanup needs the same
// privacy and process-fatal destructor boundary as registered adapters.
struct AdapterSeeds<I>(Option<I>);

impl<I: Iterator> Iterator for AdapterSeeds<I> {
    type Item = I::Item;

    fn next(&mut self) -> Option<Self::Item> {
        self.0.as_mut()?.next()
    }
}

impl<I> Drop for AdapterSeeds<I> {
    fn drop(&mut self) {
        if let Some(iterator) = self.0.take() {
            adapter_drop(iterator);
        }
    }
}

/// Deterministic caller-driven execution. One drive scans bounded waiting
/// queues, polls each active operation at most once, and starts at most one
/// command per idle resource. No threads, automatic retries, or wait loop.
/// Only bounded conforming adapters are containable in-process.
pub struct ExecutorSupervisor<P, A: DeviceAdapter<P>> {
    resources: BTreeMap<ResourceId, ResourceExecutor<P, A>>,
    consumer: QueueConsumer<P>,
    fatal: bool,
}

impl<P, A: DeviceAdapter<P>> fmt::Debug for ExecutorSupervisor<P, A> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ExecutorSupervisor")
            .field("resource_count", &self.resources.len())
            .field("fatal", &self.fatal)
            .finish_non_exhaustive()
    }
}

impl<P: CoreCommand, A: DeviceAdapter<P>> ExecutorSupervisor<P, A> {
    /// Adapters must exactly cover the bounded queue resource set. Installs the
    /// process panic-hook privacy wrapper; see crate documentation for ordering.
    pub fn new(
        consumer: QueueConsumer<P>,
        adapters: impl IntoIterator<Item = (ResourceId, A)>,
    ) -> Result<Self, CoreFatalError> {
        install_privacy_hook();
        let ids = consumer.resources();
        let mut resources = BTreeMap::new();
        for (resource, adapter) in AdapterSeeds(Some(adapters.into_iter())) {
            if resources.len() >= ids.len()
                || !ids.contains(&resource)
                || resources.contains_key(&resource)
            {
                adapter_drop(adapter);
                return Err(CoreFatalError::QueueInvariant);
            }
            resources.insert(
                resource,
                ResourceExecutor {
                    adapter: Some(adapter),
                    active: None,
                },
            );
        }
        if resources.len() != ids.len() {
            return Err(CoreFatalError::QueueInvariant);
        }
        Ok(Self {
            resources,
            consumer,
            fatal: false,
        })
    }

    /// A fatal error poisons this supervisor. The caller must abandon the Core
    /// epoch; subsequent drives perform no adapter calls.
    pub fn drive<C: AgentClock, Q: ExecutorQueuePort<P>>(
        &mut self,
        core: &mut CoreActor<P, C, Q>,
    ) -> Result<(), CoreFatalError> {
        if self.fatal {
            return Err(CoreFatalError::ExecutionInvariant);
        }
        let result = self.drive_inner(core);
        if result.is_err() {
            self.fatal = true;
        }
        result
    }

    fn drive_inner<C: AgentClock, Q: ExecutorQueuePort<P>>(
        &mut self,
        core: &mut CoreActor<P, C, Q>,
    ) -> Result<(), CoreFatalError> {
        core.observe_uptime()?;
        for (&resource, executor) in &mut self.resources {
            let now = core.observe_uptime()?;
            let removed = self.consumer.remove_if(resource, |command| {
                if command.resource() != resource {
                    return Err(CoreFatalError::QueueInvariant);
                }
                core.execution_witness(command, false)?;
                Ok(!core.binding_executable(command) || expired(command, now)?)
            })?;
            for command in removed {
                let code = if !core.binding_executable(&command) {
                    "edge.binding_fenced"
                } else {
                    "edge.execution_timeout"
                };
                core.finish_record(
                    command.command_id(),
                    now,
                    Completion::FailedNone,
                    Some(code),
                )?;
                // command drops here; no queue/operation payload reference remains.
            }

            if executor.active.is_none() && !core.resource_executable(resource) {
                discard_adapter(&mut executor.adapter);
            }

            if let Some(mut active) = executor.active.take() {
                core.execution_witness(&active.command, true)?;
                let now = core.observe_uptime()?;
                let interrupt = if !core.binding_executable(&active.command) {
                    Some("edge.binding_fenced")
                } else if expired(&active.command, now)? {
                    Some("edge.execution_timeout")
                } else {
                    None
                };
                let report = if interrupt.is_none() {
                    let record = core.execution_witness(&active.command, true)?;
                    let mut context = AdapterPollContext {
                        record,
                        effects: &mut active.tracker,
                    };
                    let operation = active
                        .operation
                        .as_mut()
                        .ok_or(CoreFatalError::ExecutionInvariant)?;
                    Some(adapter_call(|| operation.poll(&mut context)))
                } else {
                    None
                };
                // A bounded poll may still advance time to the deadline. Check
                // again before accepting its result; confirmation dominates.
                let now = core.observe_uptime()?;
                let interrupt = interrupt.or(if expired(&active.command, now)? {
                    Some("edge.execution_timeout")
                } else {
                    None
                });
                // A contradictory completion undermines None even when this
                // poll also reached the deadline. Do not let timeout precedence
                // hide a claimed, untracked effect and publish known non-effect.
                if let Some(Ok(fact)) = report
                    && !matches!(fact, AdapterPoll::Pending | AdapterPoll::BindingLost(_))
                    && active.tracker.complete(fact).is_none()
                {
                    active.tracker.contract_failure();
                }
                let (completion, code, fence) = if let Some(code) = interrupt {
                    (Some(active.tracker.interrupted()), Some(code), true)
                } else {
                    match report {
                        Some(Err(())) => (
                            Some(active.tracker.interrupted()),
                            Some("edge.adapter_panic"),
                            true,
                        ),
                        Some(Ok(_)) if active.tracker.violated() => (
                            Some(active.tracker.interrupted()),
                            Some("edge.adapter_contract"),
                            true,
                        ),
                        Some(Ok(AdapterPoll::Pending)) => (None, None, false),
                        Some(Ok(AdapterPoll::BindingLost(code))) => (
                            Some(active.tracker.interrupted()),
                            Some(code.as_str()),
                            true,
                        ),
                        Some(Ok(fact)) => {
                            let code = match fact {
                                AdapterPoll::RejectedBeforeEffect(code)
                                | AdapterPoll::KnownFailure(code) => Some(code.as_str()),
                                _ => None,
                            };
                            match active.tracker.complete(fact) {
                                Some(completion) => (Some(completion), code, false),
                                None => (
                                    Some(active.tracker.contract_failure()),
                                    Some("edge.adapter_contract"),
                                    true,
                                ),
                            }
                        }
                        None => return Err(CoreFatalError::ExecutionInvariant),
                    }
                };
                if let Some(completion) = completion {
                    // Stop all old operation activity BEFORE publishing terminal
                    // evidence. A destructor panic cannot establish cleanup
                    // and terminates the process rather than becoming a result.
                    let operation = active
                        .operation
                        .take()
                        .ok_or(CoreFatalError::ExecutionInvariant)?;
                    adapter_drop(operation);
                    if fence {
                        core.fence_binding(
                            active.command.device_id(),
                            active.command.binding_instance_id(),
                        );
                        discard_adapter(&mut executor.adapter);
                    }
                    let terminal_at = core.observe_uptime()?;
                    core.finish_record(active.command.command_id(), terminal_at, completion, code)?;
                } else {
                    executor.active = Some(active);
                }
            }

            // At most one begin, and no poll of a newly started operation in
            // this drive. Promotion releases waiting capacity immediately.
            if executor.active.is_none()
                && let Some(command) = self.consumer.pop(resource)
            {
                core.execution_witness(&command, false)?;
                let now = core.observe_uptime()?;
                if !core.binding_executable(&command) || expired(&command, now)? {
                    let code = if !core.binding_executable(&command) {
                        "edge.binding_fenced"
                    } else {
                        "edge.execution_timeout"
                    };
                    core.finish_record(
                        command.command_id(),
                        now,
                        Completion::FailedNone,
                        Some(code),
                    )?;
                    continue;
                }
                let adapter = executor
                    .adapter
                    .as_mut()
                    .ok_or(CoreFatalError::ExecutionInvariant)?;
                core.start_execution(&command)?;
                // Effect class is compiled metadata, never retry permission.
                let _effect_class = command.payload().effect_class();
                let payload = command.shared_payload();
                match adapter_call(|| adapter.begin(payload)) {
                    Ok(Ok(operation)) => {
                        let mut active = Active {
                            command,
                            operation: Some(operation),
                            tracker: EffectTracker::default(),
                        };
                        let now = core.observe_uptime()?;
                        if expired(&active.command, now)? {
                            // begin is bounded and non-effectful, but its time
                            // counts. Fence/drop before any first poll.
                            let operation = active
                                .operation
                                .take()
                                .ok_or(CoreFatalError::ExecutionInvariant)?;
                            adapter_drop(operation);
                            core.fence_binding(
                                active.command.device_id(),
                                active.command.binding_instance_id(),
                            );
                            discard_adapter(&mut executor.adapter);
                            let now = core.observe_uptime()?;
                            core.finish_record(
                                active.command.command_id(),
                                now,
                                Completion::FailedNone,
                                Some("edge.execution_timeout"),
                            )?;
                        } else {
                            executor.active = Some(active);
                        }
                    }
                    result => {
                        let code = match result {
                            Ok(Err(code)) => code.as_str(),
                            _ => "edge.adapter_panic",
                        };
                        core.fence_binding(command.device_id(), command.binding_instance_id());
                        discard_adapter(&mut executor.adapter);
                        let now = core.observe_uptime()?;
                        core.finish_record(
                            command.command_id(),
                            now,
                            Completion::FailedNone,
                            Some(code),
                        )?;
                    }
                }
            }
        }
        Ok(())
    }
}

fn expired<P>(command: &QueuedCommand<P>, now: AgentUptimeMs) -> Result<bool, CoreFatalError> {
    let elapsed = now
        .get()
        .checked_sub(command.accepted_agent_uptime_ms().get())
        .ok_or(CoreFatalError::ClockRegression)?;
    Ok(elapsed >= command.timeout_ms().get())
}

fn discard_adapter<A>(adapter: &mut Option<A>) {
    if let Some(adapter) = adapter.take() {
        adapter_drop(adapter);
    }
}

impl<P, A: DeviceAdapter<P>> Drop for ExecutorSupervisor<P, A> {
    fn drop(&mut self) {
        for executor in self.resources.values_mut() {
            executor.active.take();
            discard_adapter(&mut executor.adapter);
        }
    }
}
