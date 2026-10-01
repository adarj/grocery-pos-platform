use crate::ServerLimits;
use edge_adapter_api::DeviceAdapter;
use edge_core::{
    AdmissionDecision, AgentClock, CoreActor, CoreCommand, CoreFatalError, EventPoll,
    EventSubscription, ExecutorSupervisor, QueueProducer, SubscriptionError, SubscriptionToken,
};
use edge_protocol::{
    AgentStatusResponse, AgentUptimeMs, CommandId, CommandState, CommandSubmission, DeviceId,
    DeviceListResponse, DeviceSnapshot, ProtocolVersion, SnapshotEvent,
};
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, Ordering},
    mpsc,
};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use tokio::sync::{Notify, oneshot, watch};

pub struct MonotonicClock(Instant);

impl Default for MonotonicClock {
    fn default() -> Self {
        Self(Instant::now())
    }
}

impl AgentClock for MonotonicClock {
    fn now(&self) -> AgentUptimeMs {
        AgentUptimeMs::new(
            u64::try_from(self.0.elapsed().as_millis()).expect("agent monotonic domain exhausted"),
        )
    }
}

/// Typed transport work; payloads have already passed the strict compiled codec.
pub enum ControlOperation<P> {
    Status,
    Devices,
    Device(DeviceId),
    Command(CommandId),
    Submit(CommandSubmission<P>),
}

#[derive(Debug)]
pub enum ControlReply {
    Status(AgentStatusResponse),
    Devices(DeviceListResponse),
    Device(Option<DeviceSnapshot>),
    Command(Option<CommandState>),
    Admission(AdmissionDecision),
}

/// This value is constructed and used exclusively inside the control thread.
/// Qualification compositions may wrap it to observe safe counters/lifecycle facts.
pub trait ControlPlane<P: CoreCommand> {
    fn request(&mut self, request: ControlOperation<P>) -> Result<ControlReply, CoreFatalError>;
    fn event_cursor(&self) -> u64;
    fn subscription_active(&self, token: &SubscriptionToken) -> Result<bool, CoreFatalError>;
    fn drive(&mut self) -> Result<(), CoreFatalError>;
    fn heartbeat(&mut self) -> Result<(), CoreFatalError>;
    fn open_events(&mut self) -> Result<EventSubscription, SubscriptionError>;
    fn poll_events(&mut self, token: &SubscriptionToken) -> Result<EventPoll, CoreFatalError>;
    fn close_events(&mut self, token: &SubscriptionToken) -> Result<bool, CoreFatalError>;
}

pub struct ControlRuntime<P: CoreCommand, C: AgentClock, A: DeviceAdapter<P>> {
    pub core: CoreActor<P, C, QueueProducer<P>>,
    pub executor: ExecutorSupervisor<P, A>,
}
impl<P: CoreCommand, C: AgentClock, A: DeviceAdapter<P>> ControlPlane<P>
    for ControlRuntime<P, C, A>
{
    fn request(&mut self, request: ControlOperation<P>) -> Result<ControlReply, CoreFatalError> {
        let uptime = self.core.current_uptime()?;
        Ok(match request {
            ControlOperation::Status => ControlReply::Status(AgentStatusResponse {
                agent_instance_id: self.core.agent_instance_id().clone(),
                protocol_version: ProtocolVersion::V1,
                agent_uptime_ms: uptime,
            }),
            ControlOperation::Devices => ControlReply::Devices(DeviceListResponse {
                agent_instance_id: self.core.agent_instance_id().clone(),
                devices: self.core.device_snapshots(),
            }),
            ControlOperation::Device(id) => {
                ControlReply::Device(self.core.device_snapshot(&id).cloned())
            }
            ControlOperation::Command(id) => ControlReply::Command(self.core.command_status(&id)),
            ControlOperation::Submit(command) => {
                ControlReply::Admission(self.core.submit_command(command)?)
            }
        })
    }

    fn event_cursor(&self) -> u64 {
        self.core.event_cursor().get()
    }

    fn subscription_active(&self, token: &SubscriptionToken) -> Result<bool, CoreFatalError> {
        self.core.event_subscription_active(token)
    }

    fn drive(&mut self) -> Result<(), CoreFatalError> {
        self.executor.drive(&mut self.core)
    }

    fn heartbeat(&mut self) -> Result<(), CoreFatalError> {
        self.core.emit_heartbeat()
    }

    fn open_events(&mut self) -> Result<EventSubscription, SubscriptionError> {
        self.core.open_event_subscription()
    }

    fn poll_events(&mut self, token: &SubscriptionToken) -> Result<EventPoll, CoreFatalError> {
        self.core.poll_event(token)
    }

    fn close_events(&mut self, token: &SubscriptionToken) -> Result<bool, CoreFatalError> {
        self.core.close_event_subscription(token)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Epoch {
    Running,
    Stopped,
    Fatal,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ControlError {
    Busy,
    Closed,
}

#[derive(Debug)]
pub(crate) enum Reply {
    Value(ControlReply),
    Open(u64, SnapshotEvent),
    Event(EventPoll),
    Refused,
}

enum Work<P> {
    Request(ControlOperation<P>),
    Open,
    Poll(u64),
}

struct Message<P> {
    work: Work<P>,
    reply: oneshot::Sender<Reply>,
}

pub(crate) struct ControlHandle<P> {
    sender: mpsc::SyncSender<Message<P>>,
    pub wake: Arc<Notify>,
    cleanup: Arc<AtomicU64>,
    stop: Arc<AtomicBool>,
    pub epoch: watch::Receiver<Epoch>,
    timeout: Duration,
    pub lease_state: watch::Receiver<(u64, bool)>,
}
impl<P> Clone for ControlHandle<P> {
    fn clone(&self) -> Self {
        Self {
            sender: self.sender.clone(),
            wake: self.wake.clone(),
            cleanup: self.cleanup.clone(),
            stop: self.stop.clone(),
            epoch: self.epoch.clone(),
            timeout: self.timeout,
            lease_state: self.lease_state.clone(),
        }
    }
}
impl<P> ControlHandle<P> {
    async fn send(&self, work: Work<P>) -> Result<Reply, ControlError> {
        if *self.epoch.borrow() != Epoch::Running {
            return Err(ControlError::Closed);
        }
        let (reply, receive) = oneshot::channel();
        self.sender
            .try_send(Message { work, reply })
            .map_err(|err| match err {
                mpsc::TrySendError::Full(_) => ControlError::Busy,
                _ => ControlError::Closed,
            })?;
        // A submitted POST can still be accepted when this wait fails. The HTTP
        // layer closes the connection rather than asserting a pre-admission reject.
        tokio::time::timeout(self.timeout, receive)
            .await
            .map_err(|_| ControlError::Closed)?
            .map_err(|_| ControlError::Closed)
    }

    pub async fn request(&self, op: ControlOperation<P>) -> Result<Reply, ControlError> {
        self.send(Work::Request(op)).await
    }

    pub async fn open(&self) -> Result<Reply, ControlError> {
        self.send(Work::Open).await
    }

    pub async fn poll(&self, lease: u64) -> Result<Reply, ControlError> {
        self.send(Work::Poll(lease)).await
    }

    pub fn close(&self, lease: u64) {
        // One subscription, monotonic leases. A delayed old cleanup cannot erase
        // a newer one. This dedicated slot never needs ordinary mailbox capacity.
        self.cleanup.fetch_max(lease, Ordering::Release);
    }

    pub fn shutdown(&self) {
        self.stop.store(true, Ordering::Release);
    }
}

pub(crate) fn spawn<P, F, T>(
    factory: F,
    limits: &ServerLimits,
) -> Result<(ControlHandle<P>, JoinHandle<()>), std::io::Error>
where
    P: CoreCommand,
    F: FnOnce() -> Result<T, CoreFatalError> + Send + 'static,
    T: ControlPlane<P> + 'static,
{
    let (sender, receiver) = mpsc::sync_channel::<Message<P>>(limits.control_mailbox_capacity);
    let wake = Arc::new(Notify::new());
    let cleanup = Arc::new(AtomicU64::new(0));
    let stop = Arc::new(AtomicBool::new(false));
    let (status, epoch) = watch::channel(Epoch::Running);
    let (lease_status, lease_state) = watch::channel((0, false));
    let handle = ControlHandle {
        sender,
        wake: wake.clone(),
        cleanup: cleanup.clone(),
        stop: stop.clone(),
        epoch,
        timeout: limits.control_timeout,
        lease_state,
    };
    let cadence = limits.executor_cadence;
    let heartbeat = limits.heartbeat_interval;
    let thread = thread::Builder::new()
        .name("edge-control".into())
        .spawn(move || {
            // !Send Core/queue/token/adapter values are created here and never moved out.
            let result = (|| -> Result<(), ()> {
                let mut plane = factory().map_err(|_| ())?;
                let mut subscription: Option<(u64, SubscriptionToken)> = None;
                let mut generation = 0u64;
                let mut next_drive = Instant::now();
                let mut next_heartbeat = Instant::now() + heartbeat;
                while !stop.load(Ordering::Acquire) {
                    let previous_cursor = plane.event_cursor();
                    let closing = cleanup.swap(0, Ordering::AcqRel);
                    if subscription
                        .as_ref()
                        .is_some_and(|(lease, _)| *lease == closing)
                    {
                        let (_, token) = subscription.take().expect("checked subscription");
                        plane.close_events(&token).map_err(|_| ())?;
                        lease_status.send_replace((closing, false));
                    }
                    let now = Instant::now();
                    let wait = next_drive
                        .saturating_duration_since(now)
                        .min(next_heartbeat.saturating_duration_since(now));
                    match receiver.recv_timeout(wait) {
                        Ok(message) => {
                            let reply = match message.work {
                                Work::Request(op) => {
                                    Reply::Value(plane.request(op).map_err(|_| ())?)
                                }
                                Work::Open => match plane.open_events() {
                                    Ok(sub) => {
                                        generation = generation.checked_add(1).ok_or(())?;
                                        subscription = Some((generation, sub.token));
                                        lease_status.send_replace((generation, true));
                                        Reply::Open(generation, sub.snapshot)
                                    }
                                    Err(SubscriptionError::Fatal(_)) => return Err(()),
                                    Err(_) => Reply::Refused,
                                },
                                Work::Poll(lease) => {
                                    if let Some((current, token)) = &subscription {
                                        if *current == lease {
                                            let event = plane.poll_events(token).map_err(|_| ())?;
                                            if matches!(
                                                event,
                                                EventPoll::Closed | EventPoll::StaleToken
                                            ) {
                                                subscription = None;
                                            }
                                            Reply::Event(event)
                                        } else {
                                            Reply::Event(EventPoll::StaleToken)
                                        }
                                    } else {
                                        Reply::Event(EventPoll::Closed)
                                    }
                                }
                            };
                            if let Err(Reply::Open(lease, _)) = message.reply.send(reply)
                                && subscription
                                    .as_ref()
                                    .is_some_and(|(current, _)| *current == lease)
                            {
                                let (_, token) = subscription.take().expect("checked subscription");
                                plane.close_events(&token).map_err(|_| ())?;
                            }
                        }
                        Err(mpsc::RecvTimeoutError::Disconnected) => break,
                        Err(mpsc::RecvTimeoutError::Timeout) => {}
                    }
                    let now = Instant::now();
                    if now >= next_drive {
                        plane.drive().map_err(|_| ())?;
                        next_drive = Instant::now() + cadence;
                    }
                    if plane.event_cursor() != previous_cursor {
                        wake.notify_waiters();
                    }
                    if let Some((lease, token)) = &subscription
                        && !plane.subscription_active(token).map_err(|_| ())?
                    {
                        lease_status.send_replace((*lease, false));
                        subscription = None;
                    }
                    if now >= next_heartbeat {
                        plane.heartbeat().map_err(|_| ())?;
                        next_heartbeat = Instant::now() + heartbeat;
                        wake.notify_waiters();
                        if let Some((lease, token)) = &subscription
                            && !plane.subscription_active(token).map_err(|_| ())?
                        {
                            lease_status.send_replace((*lease, false));
                            subscription = None;
                        }
                    }
                }
                if let Some((_, token)) = subscription {
                    plane.close_events(&token).map_err(|_| ())?;
                }
                Ok(())
            })();
            // Any failure abandons the epoch, including a factory failure. Closing
            // all HTTP connections makes a lost POST response explicitly uncertain.
            status.send_replace(if result.is_ok() {
                Epoch::Stopped
            } else {
                Epoch::Fatal
            });
            wake.notify_waiters();
        })?;
    Ok((handle, thread))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use edge_adapter_api::{AdapterErrorCode, AdapterOperation, AdapterPoll, EffectClass};
    use edge_core::{CoreLimits, bounded_executor_queue};
    use edge_protocol::{AgentInstanceId, TypedCommandPayload};
    use std::sync::atomic::AtomicUsize;
    #[derive(Eq, PartialEq)]
    pub(crate) struct Payload;
    impl TypedCommandPayload for Payload {
        fn command_kind(&self) -> &'static str {
            "synthetic.signal"
        }
    }

    impl CoreCommand for Payload {
        type PayloadFingerprint = ();
        fn required_capability(&self) -> &'static str {
            "synthetic.signal"
        }

        fn effect_class(&self) -> EffectClass {
            EffectClass::DiscreteEffect
        }

        fn retained_payload_fingerprint(&self) {}
    }

    struct Adapter;
    struct Operation;
    impl DeviceAdapter<Payload> for Adapter {
        type Operation = Operation;
        fn begin(&mut self, _: Arc<Payload>) -> Result<Operation, AdapterErrorCode> {
            Ok(Operation)
        }
    }

    impl AdapterOperation for Operation {
        fn poll(&mut self, _: &mut edge_adapter_api::AdapterPollContext<'_>) -> AdapterPoll {
            AdapterPoll::Pending
        }
    }

    struct Clock(Arc<AtomicU64>);
    impl AgentClock for Clock {
        fn now(&self) -> AgentUptimeMs {
            AgentUptimeMs::new(self.0.load(Ordering::Relaxed))
        }
    }
    pub(crate) struct Plane {
        runtime: ControlRuntime<Payload, Clock, Adapter>,
        requests: Arc<AtomicUsize>,
        gate: Option<mpsc::Receiver<()>>,
        started: Option<mpsc::Sender<()>>,
        drives: Arc<AtomicUsize>,
        heartbeat_observer: Option<mpsc::Sender<()>>,
        request_drive_observer: Option<Arc<AtomicUsize>>,
    }

    impl Plane {
        fn observe_request_drives(mut self, observer: Arc<AtomicUsize>) -> Self {
            self.request_drive_observer = Some(observer);
            self
        }
        pub(crate) fn observe_heartbeats(mut self, observer: mpsc::Sender<()>) -> Self {
            self.heartbeat_observer = Some(observer);
            self
        }
        pub(crate) fn gated(mut self, gate: mpsc::Receiver<()>, started: mpsc::Sender<()>) -> Self {
            self.gate = Some(gate);
            self.started = Some(started);
            self
        }
    }

    impl ControlPlane<Payload> for Plane {
        fn request(
            &mut self,
            op: ControlOperation<Payload>,
        ) -> Result<ControlReply, CoreFatalError> {
            if let Some(observer) = &self.request_drive_observer {
                observer.store(self.drives.load(Ordering::Relaxed), Ordering::Relaxed);
            }
            self.requests.fetch_add(1, Ordering::Release);
            if let Some(gate) = self.gate.take() {
                self.started.take().unwrap().send(()).unwrap();
                gate.recv_timeout(Duration::from_secs(2)).unwrap();
            }
            self.runtime.request(op)
        }

        fn drive(&mut self) -> Result<(), CoreFatalError> {
            self.drives.fetch_add(1, Ordering::Relaxed);
            self.runtime.drive()
        }

        fn event_cursor(&self) -> u64 {
            self.runtime.event_cursor()
        }

        fn subscription_active(&self, t: &SubscriptionToken) -> Result<bool, CoreFatalError> {
            self.runtime.subscription_active(t)
        }

        fn heartbeat(&mut self) -> Result<(), CoreFatalError> {
            self.runtime.heartbeat()?;
            if let Some(observer) = &self.heartbeat_observer {
                let _ = observer.send(());
            }
            Ok(())
        }

        fn open_events(&mut self) -> Result<EventSubscription, SubscriptionError> {
            self.runtime.open_events()
        }

        fn poll_events(&mut self, t: &SubscriptionToken) -> Result<EventPoll, CoreFatalError> {
            self.runtime.poll_events(t)
        }

        fn close_events(&mut self, t: &SubscriptionToken) -> Result<bool, CoreFatalError> {
            self.runtime.close_events(t)
        }
    }
    pub(crate) fn plane(
        clock: Arc<AtomicU64>,
        requests: Arc<AtomicUsize>,
        drives: Arc<AtomicUsize>,
    ) -> Plane {
        let (producer, consumer) = bounded_executor_queue([], 1, 1).unwrap();
        let core = CoreActor::new(
            AgentInstanceId::new("test-agent").unwrap(),
            vec![],
            CoreLimits::with_registry_bounds(1, 1, 1, 1),
            Clock(clock),
            producer,
        )
        .unwrap();
        Plane {
            runtime: ControlRuntime {
                core,
                executor: ExecutorSupervisor::new(consumer).unwrap(),
            },
            requests,
            drives,
            gate: None,
            started: None,
            heartbeat_observer: None,
            request_drive_observer: None,
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn mailbox_full_fails_before_core_and_idle_drive_is_independent() {
        let requests = Arc::new(AtomicUsize::new(0));
        let drives = Arc::new(AtomicUsize::new(0));
        let limits = ServerLimits {
            control_mailbox_capacity: 1,
            ..ServerLimits::default()
        };
        let (release, gate) = mpsc::channel();
        let (started, receive) = mpsc::channel();
        let r = requests.clone();
        let d = drives.clone();
        let (handle, thread) = spawn(
            move || {
                let mut p = plane(Arc::new(AtomicU64::new(100)), r, d);
                p.gate = Some(gate);
                p.started = Some(started);
                Ok(p)
            },
            &limits,
        )
        .unwrap();
        let lease = match handle.open().await.unwrap() {
            Reply::Open(lease, _) => lease,
            _ => panic!("initial subscription"),
        };
        let (reply, _) = oneshot::channel();
        handle
            .sender
            .try_send(Message {
                work: Work::Request(ControlOperation::Status),
                reply,
            })
            .unwrap();
        receive.recv_timeout(Duration::from_secs(1)).unwrap();
        let (reply, _) = oneshot::channel();
        handle
            .sender
            .try_send(Message {
                work: Work::Request(ControlOperation::Status),
                reply,
            })
            .unwrap();
        assert!(matches!(
            handle.request(ControlOperation::Status).await,
            Err(ControlError::Busy)
        ));
        assert_eq!(requests.load(Ordering::Relaxed), 1);
        // Stream cleanup uses its dedicated slot even while the ordinary mailbox
        // is saturated; it does not queue behind a successful try_send.
        handle.close(lease);
        release.send(()).unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(requests.load(Ordering::Relaxed), 2);
        assert!(drives.load(Ordering::Relaxed) >= 2);
        let replacement = match handle.open().await.unwrap() {
            Reply::Open(lease, _) => lease,
            _ => panic!("cleanup blocked by full mailbox"),
        };
        handle.close(replacement);
        handle.shutdown();
        thread.join().unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn clock_regression_abandons_epoch_and_later_requests_cannot_run() {
        let clock = Arc::new(AtomicU64::new(100));
        let requests = Arc::new(AtomicUsize::new(0));
        let c = clock.clone();
        let r = requests.clone();
        let (handle, thread) = spawn(
            move || Ok(plane(c, r, Arc::new(AtomicUsize::new(0)))),
            &ServerLimits::default(),
        )
        .unwrap();
        assert!(matches!(
            handle.request(ControlOperation::Status).await,
            Ok(Reply::Value(_))
        ));
        clock.store(99, Ordering::Relaxed);
        let mut epoch = handle.epoch.clone();
        tokio::time::timeout(Duration::from_secs(1), epoch.changed())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(*epoch.borrow(), Epoch::Fatal);
        assert!(matches!(
            handle.request(ControlOperation::Status).await,
            Err(ControlError::Closed)
        ));
        assert_eq!(requests.load(Ordering::Relaxed), 1);
        thread.join().unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn cancelled_open_reply_releases_subscriber_and_old_cleanup_cannot_close_new() {
        let (handle, thread) = spawn(
            move || {
                Ok(plane(
                    Arc::new(AtomicU64::new(100)),
                    Arc::new(AtomicUsize::new(0)),
                    Arc::new(AtomicUsize::new(0)),
                ))
            },
            &ServerLimits::default(),
        )
        .unwrap();
        let (reply, receive) = oneshot::channel();
        drop(receive);
        handle
            .sender
            .try_send(Message {
                work: Work::Open,
                reply,
            })
            .unwrap();
        tokio::time::sleep(Duration::from_millis(30)).await;
        let first = match handle.open().await.unwrap() {
            Reply::Open(lease, _) => lease,
            _ => panic!("subscriber leaked"),
        };
        handle.close(first);
        tokio::time::sleep(Duration::from_millis(30)).await;
        let next = match handle.open().await.unwrap() {
            Reply::Open(lease, _) => lease,
            _ => panic!("subscriber leaked"),
        };
        handle.close(first);
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert!(matches!(
            handle.poll(next).await,
            Ok(Reply::Event(EventPoll::Empty))
        ));
        handle.close(next);
        handle.shutdown();
        thread.join().unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn qualification_default_mailbox_64_cancelled_replies_cleanup_and_fair_drive() {
        let limits = ServerLimits::default();
        assert_eq!(limits.control_mailbox_capacity, 64);
        let requests = Arc::new(AtomicUsize::new(0));
        let drives = Arc::new(AtomicUsize::new(0));
        let (release, gate) = mpsc::channel();
        let (started, receive) = mpsc::channel();
        let r = requests.clone();
        let d = drives.clone();
        let observed_drives = Arc::new(AtomicUsize::new(0));
        let observer = observed_drives.clone();
        let (handle, thread) = spawn(
            move || {
                Ok(plane(Arc::new(AtomicU64::new(100)), r, d)
                    .observe_request_drives(observer)
                    .gated(gate, started))
            },
            &limits,
        )
        .unwrap();
        let lease = match handle.open().await.unwrap() {
            Reply::Open(lease, _) => lease,
            _ => panic!("subscription"),
        };
        let (reply, receiver) = oneshot::channel();
        drop(receiver);
        handle
            .sender
            .try_send(Message {
                work: Work::Request(ControlOperation::Status),
                reply,
            })
            .unwrap();
        receive.recv_timeout(Duration::from_secs(1)).unwrap();
        for _ in 0..64 {
            let (reply, receiver) = oneshot::channel();
            drop(receiver);
            handle
                .sender
                .try_send(Message {
                    work: Work::Request(ControlOperation::Status),
                    reply,
                })
                .unwrap();
        }
        assert!(matches!(
            handle.request(ControlOperation::Status).await,
            Err(ControlError::Busy)
        ));
        assert_eq!(requests.load(Ordering::Relaxed), 1); // refusal never reaches Core
        handle.close(lease); // cleanup bypasses saturated mailbox
        release.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(2), async {
            while requests.load(Ordering::Relaxed) != 65 {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .unwrap();
        let new = match handle.open().await.unwrap() {
            Reply::Open(lease, _) => lease,
            _ => panic!("cleanup"),
        };
        // Keep the bounded mailbox under pressure for several drive cadences.
        // Observe progress inside request handling, so later idle drives cannot
        // accidentally satisfy the fairness assertion.
        let before = drives.load(Ordering::Relaxed);
        let sender = handle.sender.clone();
        let cadence = limits.executor_cadence;
        let sent = tokio::task::spawn_blocking(move || {
            let until = Instant::now() + cadence * 4;
            let mut count = 0;
            while count < 5000 || Instant::now() < until {
                let (reply, receiver) = oneshot::channel();
                drop(receiver);
                sender
                    .send(Message {
                        work: Work::Request(ControlOperation::Status),
                        reply,
                    })
                    .unwrap();
                count += 1;
            }
            count
        })
        .await
        .unwrap();
        tokio::time::timeout(Duration::from_secs(2), async {
            while requests.load(Ordering::Acquire) != 65 + sent {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let during = observed_drives.load(Ordering::Relaxed);
        handle.close(new);
        handle.shutdown();
        thread.join().unwrap();
        assert!(during > before + 1, "query flood starved executor drives");
    }
}
