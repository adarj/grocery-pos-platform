use std::cell::RefCell;
use std::collections::{BTreeMap, VecDeque};
use std::fmt;
use std::rc::Rc;

use edge_protocol::NonterminalCommandState;

use crate::{
    CoreFatalError, ExecutorQueuePort, QueueCommitError, QueueReservationError, QueuedCommand,
    ResourceId,
};

pub const DEFAULT_WAITING_CAPACITY: usize = 32;

struct ResourceQueue<P> {
    waiting: VecDeque<QueuedCommand<P>>,
    reserved: usize,
}

struct QueueState<P> {
    resources: BTreeMap<ResourceId, ResourceQueue<P>>,
    capacity: usize,
    consumer_alive: bool,
}

/// Single-threaded producer/consumer split, not shared Core state. No queue
/// borrow crosses an adapter call. Resource count and waiting capacity bound
/// every traversal and retained queue allocation.
pub fn bounded_executor_queue<P>(
    resources: impl IntoIterator<Item = ResourceId>,
    max_resources: usize,
    waiting_capacity: usize,
) -> Result<(QueueProducer<P>, QueueConsumer<P>), CoreFatalError> {
    if max_resources == 0 || waiting_capacity == 0 {
        return Err(CoreFatalError::InvalidLimits);
    }
    let mut queues = BTreeMap::new();
    for resource in resources {
        if queues.len() >= max_resources {
            return Err(CoreFatalError::TooManyResources);
        }
        if queues
            .insert(
                resource,
                ResourceQueue {
                    waiting: VecDeque::new(),
                    reserved: 0,
                },
            )
            .is_some()
        {
            return Err(CoreFatalError::QueueInvariant);
        }
    }
    let state = Rc::new(RefCell::new(QueueState {
        resources: queues,
        capacity: waiting_capacity,
        consumer_alive: true,
    }));
    Ok((QueueProducer(Rc::clone(&state)), QueueConsumer(state)))
}

pub struct QueueProducer<P>(Rc<RefCell<QueueState<P>>>);

pub struct QueueConsumer<P>(Rc<RefCell<QueueState<P>>>);

/// Unforgeable held waiting slot. Drop releases capacity on every pre-commit
/// exit, including fatal sequence allocation failure in Core.
pub struct QueueReservation<P> {
    state: Rc<RefCell<QueueState<P>>>,
    resource: ResourceId,
}

impl<P> Drop for QueueReservation<P> {
    fn drop(&mut self) {
        // Only this module mutates counters; every live token owns one count.
        if let Some(queue) = self.state.borrow_mut().resources.get_mut(&self.resource) {
            queue.reserved -= 1;
        }
    }
}

impl<P> QueueProducer<P> {
    pub(crate) fn owns_consumer(&self, consumer: &QueueConsumer<P>) -> bool {
        Rc::ptr_eq(&self.0, &consumer.0)
    }
}

impl<P> ExecutorQueuePort<P> for QueueProducer<P> {
    type Reservation = QueueReservation<P>;

    fn reserve(
        &mut self,
        resource: &ResourceId,
    ) -> Result<Self::Reservation, QueueReservationError> {
        let mut state = self.0.borrow_mut();
        if !state.consumer_alive {
            return Err(QueueReservationError::Unavailable);
        }
        let capacity = state.capacity;
        let queue = state
            .resources
            .get_mut(resource)
            .ok_or(QueueReservationError::Unavailable)?;
        // Subtraction keeps even a configured usize::MAX capacity safe.
        if queue.reserved >= capacity - queue.waiting.len() {
            return Err(QueueReservationError::Full);
        }
        queue.reserved += 1;
        Ok(QueueReservation {
            state: Rc::clone(&self.0),
            resource: *resource,
        })
    }

    fn commit(
        &mut self,
        reservation: Self::Reservation,
        command: QueuedCommand<P>,
        recorded: &NonterminalCommandState,
    ) -> Result<(), QueueCommitError> {
        if reservation.resource != command.resource()
            || !Rc::ptr_eq(&self.0, &reservation.state)
            || recorded.command_id != *command.command_id()
            || recorded.device_id != *command.device_id()
            || recorded.binding_instance_id != *command.binding_instance_id()
            || recorded.kind != *command.kind()
            || recorded.accepted_agent_uptime_ms != command.accepted_agent_uptime_ms()
        {
            return Err(QueueCommitError::GuaranteedNotEnqueued);
        }
        {
            let mut state = self.0.borrow_mut();
            if !state.consumer_alive {
                return Err(QueueCommitError::GuaranteedNotEnqueued);
            }
            let Some(queue) = state.resources.get_mut(&reservation.resource) else {
                return Err(QueueCommitError::GuaranteedNotEnqueued);
            };
            queue.waiting.push_back(command);
        }
        // The held count is now replaced by the waiting entry.
        drop(reservation);
        Ok(())
    }
}

impl<P> QueueConsumer<P> {
    pub(crate) fn resources(&self) -> Vec<ResourceId> {
        self.0.borrow().resources.keys().copied().collect()
    }

    pub(crate) fn pop(&mut self, resource: ResourceId) -> Option<QueuedCommand<P>> {
        self.0
            .borrow_mut()
            .resources
            .get_mut(&resource)?
            .waiting
            .pop_front()
    }

    /// Visit every waiting entry once, including expired entries behind live
    /// work. Removal preserves the FIFO order of all surviving commands.
    pub(crate) fn remove_if(
        &mut self,
        resource: ResourceId,
        mut predicate: impl FnMut(&QueuedCommand<P>) -> Result<bool, CoreFatalError>,
    ) -> Result<Vec<QueuedCommand<P>>, CoreFatalError> {
        let mut state = self.0.borrow_mut();
        let queue = state
            .resources
            .get_mut(&resource)
            .ok_or(CoreFatalError::QueueInvariant)?;
        let mut removed = Vec::new();
        let mut index = 0;
        while index < queue.waiting.len() {
            if predicate(&queue.waiting[index])? {
                if let Some(command) = queue.waiting.remove(index) {
                    removed.push(command);
                }
            } else {
                index += 1;
            }
        }
        Ok(removed)
    }
}

impl<P> Drop for QueueConsumer<P> {
    fn drop(&mut self) {
        let mut state = self.0.borrow_mut();
        state.consumer_alive = false;
        for queue in state.resources.values_mut() {
            queue.waiting.clear();
        }
    }
}

impl<P> fmt::Debug for QueueProducer<P> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("QueueProducer")
            .field("resource_count", &self.0.borrow().resources.len())
            .finish_non_exhaustive()
    }
}

impl<P> fmt::Debug for QueueConsumer<P> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("QueueConsumer")
            .field("resource_count", &self.0.borrow().resources.len())
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use edge_protocol::{
        AgentInstanceId, AgentUptimeMs, BindingInstanceId, CommandId, CommandKind,
        CommandTimeoutMs, DeviceId,
    };
    use std::sync::Arc;

    fn state(id: &str) -> NonterminalCommandState {
        NonterminalCommandState {
            agent_instance_id: AgentInstanceId::new("agent-a").unwrap(),
            command_id: CommandId::new(id).unwrap(),
            device_id: DeviceId::new("synthetic.slot").unwrap(),
            binding_instance_id: BindingInstanceId::new("binding-a").unwrap(),
            kind: CommandKind::new("synthetic.signal").unwrap(),
            accepted_agent_uptime_ms: AgentUptimeMs::new(100),
        }
    }

    fn queued(record: &NonterminalCommandState) -> QueuedCommand<()> {
        QueuedCommand::new(
            ResourceId::new(7),
            record,
            CommandTimeoutMs::new(10).unwrap(),
            Arc::new(()),
        )
    }

    #[test]
    fn commit_failure_never_publishes_and_releases_the_held_slot() {
        let (mut a, mut consumer) = bounded_executor_queue([ResourceId::new(7)], 1, 1).unwrap();
        let (mut b, _other) = bounded_executor_queue([ResourceId::new(7)], 1, 1).unwrap();
        let record = state("a");
        let token = b.reserve(&ResourceId::new(7)).unwrap();
        assert_eq!(
            a.commit(token, queued(&record), &record),
            Err(QueueCommitError::GuaranteedNotEnqueued)
        );
        assert!(consumer.pop(ResourceId::new(7)).is_none());
        assert!(b.reserve(&ResourceId::new(7)).is_ok());

        let token = a.reserve(&ResourceId::new(7)).unwrap();
        assert_eq!(
            a.commit(token, queued(&record), &state("mismatched-record")),
            Err(QueueCommitError::GuaranteedNotEnqueued)
        );
        assert!(consumer.pop(ResourceId::new(7)).is_none());
        assert!(a.reserve(&ResourceId::new(7)).is_ok());
    }

    #[test]
    fn commit_is_once_only_fifo_and_promotion_releases_waiting_capacity() {
        let (mut producer, mut consumer) =
            bounded_executor_queue([ResourceId::new(7)], 1, 2).unwrap();
        for id in ["z-first", "a-second"] {
            let record = state(id);
            let token = producer.reserve(&ResourceId::new(7)).unwrap();
            producer.commit(token, queued(&record), &record).unwrap();
        }
        assert!(matches!(
            producer.reserve(&ResourceId::new(7)),
            Err(QueueReservationError::Full)
        ));
        assert_eq!(
            consumer
                .pop(ResourceId::new(7))
                .unwrap()
                .command_id()
                .as_str(),
            "z-first"
        );
        assert!(producer.reserve(&ResourceId::new(7)).is_ok());
        assert_eq!(
            consumer
                .pop(ResourceId::new(7))
                .unwrap()
                .command_id()
                .as_str(),
            "a-second"
        );
        assert!(consumer.pop(ResourceId::new(7)).is_none());
    }
}
