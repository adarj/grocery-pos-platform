use std::collections::VecDeque;
use std::rc::Rc;

use edge_protocol::{
    CommandState, CommandStateChangedEvent, DeviceSnapshot, DeviceStateChangedEvent, EdgeEvent,
    EventCursor, EventSequence, HeartbeatEvent, JsonEncodeError, SnapshotEvent,
    encode_json_bounded,
};

use super::{AgentClock, CoreActor, CoreCommand, CoreFatalError, ExecutorQueuePort};

/// In-process capability, scoped to one Core owner and subscription generation.
/// It has no wire representation and cannot be constructed by consumers.
#[derive(Clone)]
pub struct SubscriptionToken {
    owner: Rc<()>,
    generation: u64,
}

impl std::fmt::Debug for SubscriptionToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SubscriptionToken").finish_non_exhaustive()
    }
}

#[derive(Debug)]
pub struct EventSubscription {
    pub token: SubscriptionToken,
    pub snapshot: SnapshotEvent,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SubscriptionError {
    AlreadyActive,
    SnapshotTooLarge,
    Fatal(CoreFatalError),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EventPoll {
    Event(EdgeEvent),
    Empty,
    Closed,
    StaleToken,
}

struct Subscriber {
    generation: u64,
    queue: VecDeque<EdgeEvent>,
}

#[derive(Default)]
pub(super) struct EventState {
    pub(super) sequence: u64,
    pub(super) generation: u64,
    subscriber: Option<Subscriber>,
}

impl EventState {
    pub(super) fn close(&mut self) {
        self.subscriber = None;
    }

    fn enqueue(&mut self, event: EdgeEvent, capacity: usize) {
        if let Some(subscriber) = &mut self.subscriber {
            if subscriber.queue.len() == capacity {
                // Continuity is lost. Never discard one record and keep going.
                self.close();
            } else {
                subscriber.queue.push_back(event);
            }
        }
    }
}

pub(super) struct PreparedEvent {
    sequence: u64,
    event: EdgeEvent,
}

impl<P: CoreCommand, C: AgentClock, Q: ExecutorQueuePort<P>> CoreActor<P, C, Q> {
    /// Observe continuity without draining events. Transport backpressure must
    /// notice overflow even while a socket is not ready for another record.
    pub fn event_subscription_active(
        &self,
        token: &SubscriptionToken,
    ) -> Result<bool, CoreFatalError> {
        self.ensure_live()?;
        Ok(Rc::ptr_eq(&token.owner, &self.authority)
            && self
                .events
                .subscriber
                .as_ref()
                .is_some_and(|subscriber| subscriber.generation == token.generation))
    }

    pub fn event_cursor(&self) -> EventCursor {
        EventCursor::new(self.events.sequence)
    }

    /// Snapshot capture and registration share this exclusive Core operation.
    /// The first later state event is cursor + 1; no history is replayed.
    pub fn open_event_subscription(&mut self) -> Result<EventSubscription, SubscriptionError> {
        self.ensure_live().map_err(SubscriptionError::Fatal)?;
        if self.events.subscriber.is_some() {
            return Err(SubscriptionError::AlreadyActive);
        }
        let uptime = self.observe_uptime().map_err(SubscriptionError::Fatal)?;
        let snapshot = SnapshotEvent {
            agent_instance_id: self.agent_instance_id.clone(),
            event_cursor: self.event_cursor(),
            agent_uptime_ms: uptime,
            // BTreeMap gives deterministic logical-device ordering.
            devices: self.devices.values().map(|v| v.snapshot.clone()).collect(),
        };
        match encode_json_bounded(
            &EdgeEvent::Snapshot(snapshot.clone()),
            self.limits.max_event_record_bytes,
        ) {
            Ok(_) => {}
            Err(JsonEncodeError::OutputTooLarge) => {
                return Err(SubscriptionError::SnapshotTooLarge);
            }
            Err(_) => {
                return Err(SubscriptionError::Fatal(
                    self.stop(CoreFatalError::EventNotRepresentable),
                ));
            }
        }
        let Some(generation) = self.events.generation.checked_add(1) else {
            return Err(SubscriptionError::Fatal(
                self.stop(CoreFatalError::SubscriptionGenerationOverflow),
            ));
        };
        self.events.generation = generation;
        self.events.subscriber = Some(Subscriber {
            generation,
            queue: VecDeque::new(),
        });
        Ok(EventSubscription {
            token: SubscriptionToken {
                owner: Rc::clone(&self.authority),
                generation,
            },
            snapshot,
        })
    }

    pub fn poll_event(&mut self, token: &SubscriptionToken) -> Result<EventPoll, CoreFatalError> {
        self.ensure_live()?;
        if !Rc::ptr_eq(&token.owner, &self.authority) {
            return Ok(EventPoll::StaleToken);
        }
        let Some(subscriber) = &mut self.events.subscriber else {
            return Ok(EventPoll::Closed);
        };
        if subscriber.generation != token.generation {
            return Ok(EventPoll::StaleToken);
        }
        Ok(subscriber
            .queue
            .pop_front()
            .map_or(EventPoll::Empty, EventPoll::Event))
    }

    /// A stale token cannot close the replacement subscription.
    pub fn close_event_subscription(
        &mut self,
        token: &SubscriptionToken,
    ) -> Result<bool, CoreFatalError> {
        self.ensure_live()?;
        if Rc::ptr_eq(&token.owner, &self.authority)
            && self
                .events
                .subscriber
                .as_ref()
                .is_some_and(|v| v.generation == token.generation)
        {
            self.events.close();
            Ok(true)
        } else {
            Ok(false)
        }
    }

    /// Deterministic liveness primitive. Scheduling and transport are deferred.
    pub fn emit_heartbeat(&mut self) -> Result<(), CoreFatalError> {
        let uptime = self.observe_uptime()?;
        let event = EdgeEvent::Heartbeat(HeartbeatEvent {
            agent_instance_id: self.agent_instance_id.clone(),
            agent_uptime_ms: uptime,
        });
        self.check_event(&event)?;
        self.events
            .enqueue(event, self.limits.max_event_queue_records);
        Ok(())
    }

    fn check_event(&mut self, event: &EdgeEvent) -> Result<(), CoreFatalError> {
        let result = encode_json_bounded(event, self.limits.max_event_record_bytes)
            .map(|_| ())
            .map_err(|_| CoreFatalError::EventNotRepresentable);
        self.latch(result)
    }

    fn next_event_sequence(&mut self) -> Result<u64, CoreFatalError> {
        self.ensure_live()?;
        let result = self
            .events
            .sequence
            .checked_add(1)
            .ok_or(CoreFatalError::EventSequenceOverflow);
        self.latch(result)
    }

    pub(super) fn prepare_command_event(
        &mut self,
        command: CommandState,
    ) -> Result<PreparedEvent, CoreFatalError> {
        let sequence = self.next_event_sequence()?;
        let event = EdgeEvent::CommandStateChanged(Box::new(CommandStateChangedEvent {
            agent_instance_id: self.agent_instance_id.clone(),
            sequence: EventSequence::new(sequence),
            command,
        }));
        self.check_event(&event)?;
        Ok(PreparedEvent { sequence, event })
    }

    pub(super) fn prepare_device_event(
        &mut self,
        device: DeviceSnapshot,
    ) -> Result<PreparedEvent, CoreFatalError> {
        let sequence = self.next_event_sequence()?;
        let event = EdgeEvent::DeviceStateChanged(Box::new(DeviceStateChangedEvent {
            agent_instance_id: device.agent_instance_id.clone(),
            sequence: EventSequence::new(sequence),
            device_id: device.device_id.clone(),
            binding_instance_id: device.binding_instance_id.clone(),
            state_revision: device.state_revision,
            device,
        }));
        self.check_event(&event)?;
        Ok(PreparedEvent { sequence, event })
    }

    pub(super) fn publish_state_event(&mut self, prepared: PreparedEvent) {
        self.events.sequence = prepared.sequence;
        self.events
            .enqueue(prepared.event, self.limits.max_event_queue_records);
    }
}
