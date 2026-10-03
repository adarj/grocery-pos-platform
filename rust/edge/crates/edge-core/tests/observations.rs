use std::cell::Cell;
use std::collections::{BTreeSet, VecDeque};
use std::rc::Rc;
use std::sync::Arc;

use edge_adapter_api::*;
use edge_core::*;
use edge_protocol::*;

#[derive(Eq, PartialEq)]
struct Payload(bool);
impl TypedCommandPayload for Payload {
    fn command_kind(&self) -> &'static str {
        if self.0 {
            "scanner.barcode"
        } else {
            "synthetic.signal"
        }
    }
}

impl CoreCommand for Payload {
    type PayloadFingerprint = bool;
    fn required_capability(&self) -> &'static str {
        self.command_kind()
    }

    fn effect_class(&self) -> EffectClass {
        EffectClass::DiscreteEffect
    }

    fn retained_payload_fingerprint(&self) -> bool {
        self.0
    }
}

struct Clock;
impl AgentClock for Clock {
    fn now(&self) -> AgentUptimeMs {
        AgentUptimeMs::new(100)
    }
}

struct Adapter(Rc<Cell<usize>>);
struct Operation;
impl DeviceAdapter<Payload> for Adapter {
    type Operation = Operation;
    fn begin(&mut self, _: Arc<Payload>) -> Result<Operation, AdapterErrorCode> {
        self.0.set(self.0.get() + 1);
        Ok(Operation)
    }
}

impl AdapterOperation for Operation {
    fn poll(&mut self, c: &mut AdapterPollContext<'_>) -> AdapterPoll {
        c.effects.mark_possible();
        c.effects.mark_confirmed().unwrap();
        AdapterPoll::Succeeded
    }
}

struct Source {
    steps: VecDeque<ObservationPoll>,
    polls: Rc<Cell<usize>>,
    drops: Rc<Cell<usize>>,
    panic: bool,
}

impl ObservationSource for Source {
    fn poll(&mut self) -> ObservationPoll {
        self.polls.set(self.polls.get() + 1);
        assert!(!self.panic, "PRIVATE_BARCODE_PANIC");
        self.steps.pop_front().unwrap_or(ObservationPoll::Pending)
    }
}

impl Drop for Source {
    fn drop(&mut self) {
        self.drops.set(self.drops.get() + 1);
    }
}

type Core = CoreActor<Payload, Clock, QueueProducer<Payload>>;
fn cap(s: &str) -> Capability {
    Capability::new(s).unwrap()
}

fn device() -> DeviceId {
    DeviceId::new("scanner").unwrap()
}

fn binding(s: &str) -> BindingInstanceId {
    BindingInstanceId::new(s).unwrap()
}

fn value() -> DeviceObservation {
    DeviceObservation::ScannerBarcode {
        barcode: BarcodeValue::new("049000001234").unwrap(),
    }
}

fn source(steps: Vec<ObservationPoll>) -> Source {
    Source {
        steps: steps.into(),
        polls: Rc::default(),
        drops: Rc::default(),
        panic: false,
    }
}

fn fixture(
    command: bool,
    observation: bool,
) -> (
    Core,
    ExecutorSupervisor<Payload, Adapter>,
    ObservationSupervisor<Source>,
) {
    fixture_with_adapter(command, observation)
}

fn fixture_with_adapter<A: DeviceAdapter<Payload>>(
    command: bool,
    observation: bool,
) -> (
    Core,
    ExecutorSupervisor<Payload, A>,
    ObservationSupervisor<Source>,
) {
    let resources = if command {
        vec![(cap("synthetic.signal"), ResourceId::new(1))]
    } else {
        vec![]
    };
    let (producer, consumer) =
        bounded_executor_queue(resources.iter().map(|(_, r)| *r), 2, 2).unwrap();
    let core = CoreActor::new(
        AgentInstanceId::new("agent").unwrap(),
        vec![CoreDeviceSeed {
            snapshot: DeviceSnapshot {
                agent_instance_id: AgentInstanceId::new("agent").unwrap(),
                device_id: device(),
                binding_instance_id: None,
                state_revision: StateRevision::new(0),
                adapter_kind: AdapterKind::new("synthetic").unwrap(),
                availability: DeviceAvailability::Absent,
                capabilities: BTreeSet::new(),
                conditions: BTreeSet::new(),
            },
            allowed_capabilities: [
                command.then(|| cap("synthetic.signal")),
                observation.then(|| cap("scanner.barcode")),
            ]
            .into_iter()
            .flatten()
            .collect(),
            capability_resources: resources,
        }],
        CoreLimits::with_registry_bounds(2, 2, 2, 2),
        Clock,
        producer,
    )
    .unwrap();
    (
        core,
        ExecutorSupervisor::new(consumer).unwrap(),
        ObservationSupervisor::new(),
    )
}

fn state(command: bool, observation: bool) -> BoundDeviceState {
    BoundDeviceState {
        availability: BoundAvailability::Ready,
        conditions: BTreeSet::new(),
        capabilities: [
            command.then(|| cap("synthetic.signal")),
            observation.then(|| cap("scanner.barcode")),
        ]
        .into_iter()
        .flatten()
        .collect(),
    }
}

fn install(
    core: &mut Core,
    obs: &mut ObservationSupervisor<Source>,
    b: &str,
    s: Source,
) -> BindingInstallationWitness {
    core.begin_connecting(&device()).unwrap();
    obs.install_binding(
        core,
        &device(),
        &binding(b),
        [cap("scanner.barcode")].into(),
        s,
    )
    .unwrap()
}

fn command(barcode: bool) -> CommandSubmission<Payload> {
    CommandSubmission {
        request_id: RequestId::new("request").unwrap(),
        command_id: CommandId::new("command").unwrap(),
        expected_agent_instance_id: AgentInstanceId::new("agent").unwrap(),
        device_id: device(),
        expected_binding_instance_id: binding("a"),
        not_after_agent_uptime_ms: AgentUptimeMs::new(110),
        kind: CommandKind::new(Payload(barcode).command_kind()).unwrap(),
        timeout_ms: CommandTimeoutMs::new(10).unwrap(),
        payload: Payload(barcode),
    }
}

fn two_devices() -> (
    Core,
    ObservationSupervisor<Source>,
    ExecutorSupervisor<Payload, Adapter>,
) {
    let seeds = ["a", "b"].map(|name| CoreDeviceSeed {
        snapshot: DeviceSnapshot {
            agent_instance_id: AgentInstanceId::new("agent").unwrap(),
            device_id: DeviceId::new(name).unwrap(),
            binding_instance_id: None,
            state_revision: StateRevision::new(0),
            adapter_kind: AdapterKind::new("synthetic").unwrap(),
            availability: DeviceAvailability::Absent,
            capabilities: BTreeSet::new(),
            conditions: BTreeSet::new(),
        },
        allowed_capabilities: vec![cap("scanner.barcode")],
        capability_resources: vec![],
    });
    let (producer, consumer) = bounded_executor_queue([], 2, 2).unwrap();
    (
        CoreActor::new(
            AgentInstanceId::new("agent").unwrap(),
            seeds.into(),
            CoreLimits::with_registry_bounds(2, 2, 2, 2),
            Clock,
            producer,
        )
        .unwrap(),
        ObservationSupervisor::new(),
        ExecutorSupervisor::new(consumer).unwrap(),
    )
}

#[test]
fn component_proofs_for_different_devices_cannot_combine() {
    let (mut core, mut observations, _) = two_devices();
    let proofs: Vec<_> = ["a", "b"]
        .into_iter()
        .map(|name| {
            let device = DeviceId::new(name).unwrap();
            core.begin_connecting(&device).unwrap();
            observations
                .install_binding(
                    &mut core,
                    &device,
                    &binding("same-pending-id"),
                    [cap("scanner.barcode")].into(),
                    source(vec![]),
                )
                .unwrap()
        })
        .collect();
    let mut proofs = proofs.into_iter();
    assert!(
        proofs
            .next()
            .unwrap()
            .combine(proofs.next().unwrap())
            .is_err()
    );
    observations.reap(&mut core).unwrap();
    for name in ["a", "b"] {
        assert!(
            observations
                .publication_token(&DeviceId::new(name).unwrap())
                .is_none()
        );
    }
}

#[test]
fn one_busy_source_cannot_monopolize_a_drive() {
    let (mut core, mut observations, _executor) = two_devices();
    let mut counts = vec![];
    for name in ["b", "a"] {
        let device = DeviceId::new(name).unwrap();
        core.begin_connecting(&device).unwrap();
        let s = source(vec![ObservationPoll::Observation(value()); 3]);
        counts.push(s.polls.clone());
        let proof = observations
            .install_binding(
                &mut core,
                &device,
                &binding(name),
                [cap("scanner.barcode")].into(),
                s,
            )
            .unwrap();
        core.activate_binding(proof, state(false, true)).unwrap();
    }
    let sub = core.open_event_subscription().unwrap();
    for drive in 1..=3 {
        observations.drive(&mut core).unwrap();
        for count in &counts {
            assert_eq!(count.get(), drive);
        }
        for name in ["a", "b"] {
            let EventPoll::Event(EdgeEvent::DeviceObservation(e)) =
                core.poll_event(&sub.token).unwrap()
            else {
                panic!("observation required")
            };
            assert_eq!(e.device_id.as_str(), name);
        }
        assert_eq!(core.poll_event(&sub.token).unwrap(), EventPoll::Empty);
    }
}

#[test]
fn observation_only_complete_install_never_grants_command_authority() {
    let (mut core, mut executor, mut obs) = fixture(false, true);
    core.begin_connecting(&device()).unwrap();
    assert!(
        executor
            .install_binding(&mut core, &device(), &binding("a"), [])
            .is_err()
    );
    let proof = install(&mut core, &mut obs, "a", source(vec![]));
    core.activate_binding(proof, state(false, true)).unwrap();
    let cursor = core.event_cursor();
    assert_eq!(
        core.submit_command(command(true)).unwrap(),
        AdmissionDecision::Rejected(AdmissionRejection::CapabilityUnavailable)
    );
    assert_eq!(core.retained_command_count(), 0);
    assert_eq!(core.event_cursor(), cursor);
}

#[test]
fn mixed_runtime_needs_both_components_and_executes_both_paths() {
    let (mut core, mut executor, mut obs) = fixture(true, true);
    core.begin_connecting(&device()).unwrap();
    let starts = Rc::new(Cell::new(0));
    let proof = executor
        .install_binding(
            &mut core,
            &device(),
            &binding("a"),
            [(ResourceId::new(1), Adapter(starts.clone()))],
        )
        .unwrap();
    assert_eq!(
        core.activate_binding(proof, state(true, true)),
        Err(LifecycleError::Rejected(
            LifecycleRejection::IncompleteInstallation
        ))
    );
    let proof = install(&mut core, &mut obs, "a", source(vec![]));
    assert_eq!(
        core.activate_binding(proof, state(true, true)),
        Err(LifecycleError::Rejected(
            LifecycleRejection::IncompleteInstallation
        ))
    );
    let command = executor
        .install_binding(
            &mut core,
            &device(),
            &binding("a"),
            [(ResourceId::new(1), Adapter(starts.clone()))],
        )
        .unwrap();
    let observation = install(
        &mut core,
        &mut obs,
        "a",
        source(vec![
            ObservationPoll::Observation(value()),
            ObservationPoll::Observation(value()),
        ]),
    );
    core.activate_binding(command.combine(observation).unwrap(), state(true, true))
        .unwrap();
    let sub = core.open_event_subscription().unwrap();
    assert!(matches!(
        core.submit_command(self::command(false)).unwrap(),
        AdmissionDecision::Accepted(_)
    ));
    executor.drive(&mut core).unwrap();
    obs.drive(&mut core).unwrap();
    executor.drive(&mut core).unwrap();
    obs.drive(&mut core).unwrap();
    assert_eq!(starts.get(), 1);
    assert!(matches!(
        core.command_status(&CommandId::new("command").unwrap()),
        Some(CommandState::Terminal(TerminalCommandState {
            outcome: TerminalOutcome::Succeeded,
            effect_evidence: EffectEvidence::Confirmed,
            ..
        }))
    ));
    let mut events = vec![];
    while let EventPoll::Event(e) = core.poll_event(&sub.token).unwrap() {
        events.push(e);
    }
    assert_eq!(
        events
            .iter()
            .map(|e| match e {
                EdgeEvent::CommandStateChanged(_) => "command",
                EdgeEvent::DeviceObservation(_) => "observation",
                _ => "unexpected",
            })
            .collect::<Vec<_>>(),
        [
            "command",
            "command",
            "observation",
            "command",
            "observation"
        ]
    );
    for (index, event) in events.iter().enumerate() {
        let sequence = match event {
            EdgeEvent::CommandStateChanged(e) => e.sequence,
            EdgeEvent::DeviceObservation(e) => e.sequence,
            _ => panic!("unexpected mixed event"),
        };
        assert_eq!(
            sequence.get(),
            sub.snapshot.event_cursor.get() + index as u64 + 1
        );
    }
    assert_eq!(
        core.event_cursor().get(),
        sub.snapshot.event_cursor.get() + 5
    );
}

#[test]
fn repeated_barcodes_are_distinct_one_poll_per_drive_revision_unchanged() {
    let (mut core, _, mut obs) = fixture(false, true);
    let s = source(vec![
        ObservationPoll::Pending,
        ObservationPoll::Observation(value()),
        ObservationPoll::Observation(value()),
    ]);
    let polls = s.polls.clone();
    let proof = install(&mut core, &mut obs, "a", s);
    obs.drive(&mut core).unwrap();
    assert_eq!(polls.get(), 0);
    core.activate_binding(proof, state(false, true)).unwrap();
    let sub = core.open_event_subscription().unwrap();
    let revision = core.device_snapshot(&device()).unwrap().state_revision;
    obs.drive(&mut core).unwrap();
    assert_eq!(polls.get(), 1);
    assert_eq!(core.poll_event(&sub.token).unwrap(), EventPoll::Empty);
    for n in 1..=2 {
        obs.drive(&mut core).unwrap();
        let EventPoll::Event(EdgeEvent::DeviceObservation(e)) =
            core.poll_event(&sub.token).unwrap()
        else {
            panic!("observation required")
        };
        assert_eq!(e.sequence.get(), sub.snapshot.event_cursor.get() + n);
        assert_eq!(e.state_revision, revision);
        assert_eq!(e.observation, value());
    }
    assert_eq!(polls.get(), 3);
    assert_eq!(
        core.device_snapshot(&device()).unwrap().state_revision,
        revision
    );
}

#[test]
fn old_runtime_cannot_publish_or_consume_sequence_after_replacement() {
    let (mut core, _, mut obs) = fixture(false, true);
    let proof = install(&mut core, &mut obs, "a", source(vec![]));
    core.activate_binding(proof, state(false, true)).unwrap();
    let old = obs.publication_token(&device()).unwrap();
    core.invalidate_binding(&device(), &binding("a"), BindingInvalidation::Disconnected)
        .unwrap();
    let proof = install(&mut core, &mut obs, "b", source(vec![]));
    core.activate_binding(proof, state(false, true)).unwrap();
    let snapshot = core.device_snapshot(&device()).unwrap().clone();
    let cursor = core.event_cursor();
    assert_eq!(
        core.publish_observation(&old, value()).unwrap(),
        ObservationDisposition::Fenced
    );
    assert_eq!(core.event_cursor(), cursor);
    assert_eq!(core.device_snapshot(&device()), Some(&snapshot));
    assert_eq!(
        core.invalidate_binding(
            &device(),
            &binding("a"),
            BindingInvalidation::ObservationContinuityLost
        )
        .unwrap(),
        LifecycleChange::Stale
    );
    core.invalidate_binding(&device(), &binding("b"), BindingInvalidation::Disconnected)
        .unwrap();
    core.begin_connecting(&device()).unwrap();
    assert!(matches!(
        obs.install_binding(
            &mut core,
            &device(),
            &binding("a"),
            [cap("scanner.barcode")].into(),
            source(vec![])
        ),
        Err(LifecycleError::Rejected(LifecycleRejection::BindingIdUsed))
    ));
}

#[test]
fn absent_published_capability_does_not_consume_sequence() {
    let (mut core, _, mut obs) = fixture(false, true);
    let proof = install(&mut core, &mut obs, "a", source(vec![]));
    core.activate_binding(proof, state(false, false)).unwrap();
    let cursor = core.event_cursor();
    assert_eq!(
        core.publish_observation(&obs.publication_token(&device()).unwrap(), value())
            .unwrap(),
        ObservationDisposition::CapabilityUnavailable
    );
    assert_eq!(core.event_cursor(), cursor);
}

#[test]
fn abandoned_replaced_or_dropped_source_proof_cannot_activate() {
    let (mut core, _, mut obs) = fixture(false, true);
    let s = source(vec![]);
    let drops = s.drops.clone();
    let proof = install(&mut core, &mut obs, "a", s);
    drop(proof);
    obs.reap(&mut core).unwrap();
    assert_eq!(drops.get(), 1);
    let old = install(&mut core, &mut obs, "a", source(vec![]));
    let new = install(&mut core, &mut obs, "b", source(vec![]));
    assert_eq!(
        core.activate_binding(old, state(false, true)),
        Err(LifecycleError::Rejected(
            LifecycleRejection::StaleInstallation
        ))
    );
    drop(obs);
    assert_eq!(
        core.activate_binding(new, state(false, true)),
        Err(LifecycleError::Rejected(
            LifecycleRejection::StaleInstallation
        ))
    );
}

#[test]
fn a_second_supervisor_cancels_the_first_source_and_installation_proof() {
    let (mut core, _, mut first) = fixture(false, true);
    let s = source(vec![ObservationPoll::Observation(value())]);
    let polls = s.polls.clone();
    let drops = s.drops.clone();
    let old = install(&mut core, &mut first, "a", s);
    let token = first.publication_token(&device()).unwrap();
    let mut second = ObservationSupervisor::new();
    let new = install(&mut core, &mut second, "a", source(vec![]));
    assert_eq!(
        core.activate_binding(old, state(false, true)),
        Err(LifecycleError::Rejected(
            LifecycleRejection::StaleInstallation
        ))
    );
    core.activate_binding(new, state(false, true)).unwrap();
    let cursor = core.event_cursor();
    first.drive(&mut core).unwrap();
    assert_eq!(polls.get(), 0);
    assert_eq!(drops.get(), 1);
    assert_eq!(
        core.publish_observation(&token, value()).unwrap(),
        ObservationDisposition::Fenced
    );
    assert_eq!(core.event_cursor(), cursor);
}

#[test]
fn observation_destructor_panic_is_private_and_process_fatal() {
    const NAME: &str = "observation_destructor_panic_is_private_and_process_fatal";
    if std::env::var_os("OBS_DROP_CHILD").is_some() {
        struct BadDrop;
        impl ObservationSource for BadDrop {
            fn poll(&mut self) -> ObservationPoll {
                ObservationPoll::Pending
            }
        }
        impl Drop for BadDrop {
            fn drop(&mut self) {
                panic!("PRIVATE_BARCODE_DROP");
            }
        }
        let (mut core, _, _) = fixture(false, true);
        core.begin_connecting(&device()).unwrap();
        let mut observations = ObservationSupervisor::new();
        let witness = observations
            .install_binding(
                &mut core,
                &device(),
                &binding("a"),
                [cap("scanner.barcode")].into(),
                BadDrop,
            )
            .unwrap();
        drop(witness);
        observations.reap(&mut core).unwrap();
        unreachable!("destructor panic must abort");
    }
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", NAME, "--nocapture"])
        .env("OBS_DROP_CHILD", "1")
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(!String::from_utf8_lossy(&output.stderr).contains("PRIVATE_BARCODE_DROP"));
}

#[test]
fn proof_rejects_wrong_owner_and_stale_connecting_revision() {
    let (mut core, _, mut obs) = fixture(false, true);
    let proof = install(&mut core, &mut obs, "a", source(vec![]));
    core.update_unbound_state(&device(), DeviceAvailability::Absent, BTreeSet::new())
        .unwrap();
    core.begin_connecting(&device()).unwrap();
    assert_eq!(
        core.activate_binding(proof, state(false, true)),
        Err(LifecycleError::Rejected(
            LifecycleRejection::StaleInstallation
        ))
    );
    let proof = install(&mut core, &mut obs, "a", source(vec![]));
    let (mut other, _, _) = fixture(false, true);
    other.begin_connecting(&device()).unwrap();
    assert_eq!(
        other.activate_binding(proof, state(false, true)),
        Err(LifecycleError::Fatal(
            CoreFatalError::BindingInstallationInvariant
        ))
    );
}

#[test]
fn composite_proofs_cannot_join_different_bindings_or_cores() {
    let (mut core, mut executor, mut obs) = fixture(true, true);
    core.begin_connecting(&device()).unwrap();
    let a = executor
        .install_binding(
            &mut core,
            &device(),
            &binding("a"),
            [(ResourceId::new(1), Adapter(Rc::default()))],
        )
        .unwrap();
    let b = install(&mut core, &mut obs, "b", source(vec![]));
    assert!(a.combine(b).is_err());
    let a = install(&mut core, &mut obs, "a", source(vec![]));
    let (mut other, _, mut other_obs) = fixture(false, true);
    let b = install(&mut other, &mut other_obs, "a", source(vec![]));
    assert!(a.combine(b).is_err());
}

#[test]
fn source_loss_continuity_and_panic_fence_and_drop_before_state_publication() {
    for (poll, panic, availability, code) in [
        (
            ObservationPoll::BindingLost(AdapterErrorCode::new("sim.lost")),
            false,
            DeviceAvailability::Absent,
            None,
        ),
        (
            ObservationPoll::ContinuityLost(AdapterErrorCode::new("sim.loss")),
            false,
            DeviceAvailability::Faulted,
            Some("edge.observation_continuity_lost"),
        ),
        (
            ObservationPoll::Pending,
            true,
            DeviceAvailability::Faulted,
            Some("edge.observation_fault"),
        ),
    ] {
        let (mut core, _, mut obs) = fixture(false, true);
        let mut s = source(vec![poll]);
        s.panic = panic;
        let drops = s.drops.clone();
        let polls = s.polls.clone();
        let proof = install(&mut core, &mut obs, "a", s);
        core.activate_binding(proof, state(false, true)).unwrap();
        obs.drive(&mut core).unwrap();
        assert_eq!(drops.get(), 1);
        assert_eq!(polls.get(), 1);
        let d = core.device_snapshot(&device()).unwrap();
        assert_eq!(d.availability, availability);
        assert!(d.binding_instance_id.is_none());
        assert!(d.capabilities.is_empty());
        assert_eq!(d.conditions.iter().next().map(ConditionCode::as_str), code);
        obs.drive(&mut core).unwrap();
        assert_eq!(polls.get(), 1);
    }
}

#[test]
fn observation_overflow_closes_continuity_and_reconnect_never_replays() {
    let (mut core, _, mut obs) = fixture(false, true);
    let proof = install(
        &mut core,
        &mut obs,
        "a",
        source(vec![ObservationPoll::Observation(value()); 258]),
    );
    core.activate_binding(proof, state(false, true)).unwrap();
    // No subscriber: ephemeral observation only advances current cursor.
    let before = core.event_cursor();
    let device_before = core.device_snapshot(&device()).unwrap().clone();
    obs.drive(&mut core).unwrap();
    assert_eq!(core.event_cursor().get(), before.get() + 1);
    let sub = core.open_event_subscription().unwrap();
    assert_eq!(sub.snapshot.event_cursor, core.event_cursor());
    assert_eq!(core.poll_event(&sub.token).unwrap(), EventPoll::Empty);
    for _ in 0..257 {
        obs.drive(&mut core).unwrap();
    }
    assert_eq!(core.poll_event(&sub.token).unwrap(), EventPoll::Closed);
    assert_eq!(core.device_snapshot(&device()), Some(&device_before));
    let reconnect = core.open_event_subscription().unwrap();
    assert_eq!(
        reconnect.snapshot.event_cursor.get(),
        sub.snapshot.event_cursor.get() + 257
    );
    assert_eq!(core.poll_event(&reconnect.token).unwrap(), EventPoll::Empty);
}

#[test]
fn observation_panic_diagnostics_do_not_expose_payload() {
    const NAME: &str = "observation_panic_diagnostics_do_not_expose_payload";
    if std::env::var_os("OBS_PANIC_CHILD").is_some() {
        source_loss_continuity_and_panic_fence_and_drop_before_state_publication();
        return;
    }
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", NAME, "--nocapture"])
        .env("OBS_PANIC_CHILD", "1")
        .output()
        .unwrap();
    assert!(output.status.success());
    assert!(!String::from_utf8_lossy(&output.stderr).contains("PRIVATE_BARCODE_PANIC"));
    assert!(!String::from_utf8_lossy(&output.stdout).contains("PRIVATE_BARCODE_PANIC"));
}

#[derive(Clone, Default)]
struct RuntimeCounts {
    begins: Rc<Cell<usize>>,
    polls: Rc<Cell<usize>>,
    operation_drops: Rc<Cell<usize>>,
    adapter_drops: Rc<Cell<usize>>,
}

struct HoldingAdapter {
    counts: RuntimeCounts,
    possible: bool,
    fault: bool,
}

struct HoldingOperation {
    counts: RuntimeCounts,
    possible: bool,
    fault: bool,
}

impl DeviceAdapter<Payload> for HoldingAdapter {
    type Operation = HoldingOperation;
    fn begin(&mut self, _: Arc<Payload>) -> Result<Self::Operation, AdapterErrorCode> {
        self.counts.begins.set(self.counts.begins.get() + 1);
        Ok(HoldingOperation {
            counts: self.counts.clone(),
            possible: self.possible,
            fault: self.fault,
        })
    }
}

impl AdapterOperation for HoldingOperation {
    fn poll(&mut self, context: &mut AdapterPollContext<'_>) -> AdapterPoll {
        self.counts.polls.set(self.counts.polls.get() + 1);
        if self.possible {
            context.effects.mark_possible();
        }
        if self.fault {
            AdapterPoll::BindingLost(AdapterErrorCode::new("sim.binding_lost"))
        } else {
            AdapterPoll::Pending
        }
    }
}

impl Drop for HoldingOperation {
    fn drop(&mut self) {
        self.counts
            .operation_drops
            .set(self.counts.operation_drops.get() + 1);
    }
}

impl Drop for HoldingAdapter {
    fn drop(&mut self) {
        self.counts
            .adapter_drops
            .set(self.counts.adapter_drops.get() + 1);
    }
}

fn activate_mixed(
    core: &mut Core,
    executor: &mut ExecutorSupervisor<Payload, HoldingAdapter>,
    observations: &mut ObservationSupervisor<Source>,
    epoch: &str,
    adapter: HoldingAdapter,
    source: Source,
) {
    core.begin_connecting(&device()).unwrap();
    let commands = executor
        .install_binding(
            core,
            &device(),
            &binding(epoch),
            [(ResourceId::new(1), adapter)],
        )
        .unwrap();
    let observations = observations
        .install_binding(
            core,
            &device(),
            &binding(epoch),
            [cap("scanner.barcode")].into(),
            source,
        )
        .unwrap();
    core.activate_binding(commands.combine(observations).unwrap(), state(true, true))
        .unwrap();
}

#[test]
fn observation_failure_fences_queued_and_executing_commands_for_the_entire_epoch() {
    for stage in 0..=2 {
        for failure in 0..=2 {
            let (mut core, mut executor, mut observations) = fixture_with_adapter(true, true);
            let counts = RuntimeCounts::default();
            let poll = match failure {
                0 => ObservationPoll::BindingLost(AdapterErrorCode::new("sim.lost")),
                1 => ObservationPoll::ContinuityLost(AdapterErrorCode::new("sim.loss")),
                _ => ObservationPoll::Pending,
            };
            let mut s = source(vec![poll]);
            s.panic = failure == 2;
            let source_polls = s.polls.clone();
            let source_drops = s.drops.clone();
            activate_mixed(
                &mut core,
                &mut executor,
                &mut observations,
                "a",
                HoldingAdapter {
                    counts: counts.clone(),
                    possible: stage == 2,
                    fault: false,
                },
                s,
            );
            assert!(matches!(
                core.submit_command(command(false)).unwrap(),
                AdmissionDecision::Accepted(_)
            ));
            if stage > 0 {
                executor.drive(&mut core).unwrap(); // begin, without physical poll
            }
            if stage == 2 {
                executor.drive(&mut core).unwrap(); // known possible effect, still pending
            }
            observations.drive(&mut core).unwrap();
            assert!(
                core.device_snapshot(&device())
                    .unwrap()
                    .binding_instance_id
                    .is_none()
            );
            assert!(
                core.device_snapshot(&device())
                    .unwrap()
                    .capabilities
                    .is_empty()
            );
            let mut next = command(false);
            next.command_id = CommandId::new("second").unwrap();
            assert_eq!(
                core.submit_command(next).unwrap(),
                AdmissionDecision::Rejected(AdmissionRejection::BindingInstanceConflict)
            );
            let begins = counts.begins.get();
            let polls = counts.polls.get();
            executor.drive(&mut core).unwrap(); // retirement must never begin/poll old work
            assert_eq!(counts.begins.get(), begins);
            assert_eq!(counts.polls.get(), polls);
            assert_eq!(counts.adapter_drops.get(), 1);
            assert_eq!(counts.operation_drops.get(), usize::from(stage > 0));
            assert!(
                matches!(core.command_status(&CommandId::new("command").unwrap()),
                Some(CommandState::Terminal(t)) if t.outcome == if stage == 2 { TerminalOutcome::Unknown } else { TerminalOutcome::Failed }
                    && t.effect_evidence == if stage == 2 { EffectEvidence::Possible } else { EffectEvidence::None })
            );
            // Replacement installs fresh components; old queued/active identities
            // and delayed losses cannot migrate into B.
            let replacement = RuntimeCounts::default();
            activate_mixed(
                &mut core,
                &mut executor,
                &mut observations,
                "b",
                HoldingAdapter {
                    counts: replacement.clone(),
                    possible: false,
                    fault: false,
                },
                source(vec![]),
            );
            observations.drive(&mut core).unwrap();
            executor.drive(&mut core).unwrap();
            assert_eq!(replacement.begins.get(), 0);
            assert_eq!(source_polls.get(), 1);
            assert_eq!(source_drops.get(), 1);
        }
    }
}

#[test]
fn command_binding_fault_reaps_observations_without_polling_or_sequence_consumption() {
    let (mut core, mut executor, mut observations) = fixture_with_adapter(true, true);
    let counts = RuntimeCounts::default();
    let s = source(vec![ObservationPoll::Observation(value())]);
    let polls = s.polls.clone();
    let drops = s.drops.clone();
    activate_mixed(
        &mut core,
        &mut executor,
        &mut observations,
        "a",
        HoldingAdapter {
            counts,
            possible: true,
            fault: true,
        },
        s,
    );
    let old = observations.publication_token(&device()).unwrap();
    assert!(matches!(
        core.submit_command(command(false)).unwrap(),
        AdmissionDecision::Accepted(_)
    ));
    executor.drive(&mut core).unwrap();
    executor.drive(&mut core).unwrap(); // command-side loss invalidates the complete binding
    let cursor = core.event_cursor();
    observations.drive(&mut core).unwrap();
    assert_eq!(polls.get(), 0);
    assert_eq!(drops.get(), 1);
    assert_eq!(core.event_cursor(), cursor);
    assert_eq!(
        core.publish_observation(&old, value()).unwrap(),
        ObservationDisposition::Fenced
    );
    activate_mixed(
        &mut core,
        &mut executor,
        &mut observations,
        "b",
        HoldingAdapter {
            counts: RuntimeCounts::default(),
            possible: false,
            fault: false,
        },
        source(vec![]),
    );
    let current = core.device_snapshot(&device()).unwrap().clone();
    let cursor = core.event_cursor();
    assert_eq!(
        core.publish_observation(&old, value()).unwrap(),
        ObservationDisposition::Fenced
    );
    assert_eq!(core.event_cursor(), cursor);
    assert_eq!(core.device_snapshot(&device()), Some(&current));
}

#[test]
fn replacing_either_component_invalidates_the_old_combined_proof() {
    for replace_observation in [true, false] {
        let (mut core, mut executor, mut observations) = fixture(true, true);
        core.begin_connecting(&device()).unwrap();
        let command = executor
            .install_binding(
                &mut core,
                &device(),
                &binding("a"),
                [(ResourceId::new(1), Adapter(Rc::default()))],
            )
            .unwrap();
        let s = source(vec![ObservationPoll::Observation(value())]);
        let polls = s.polls.clone();
        let old = install(&mut core, &mut observations, "a", s);
        let old = command.combine(old).unwrap();
        let replacement = if replace_observation {
            install(&mut core, &mut observations, "a", source(vec![]))
        } else {
            executor
                .install_binding(
                    &mut core,
                    &device(),
                    &binding("a"),
                    [(ResourceId::new(1), Adapter(Rc::default()))],
                )
                .unwrap()
        };
        assert_eq!(
            core.activate_binding(old, state(true, true)),
            Err(LifecycleError::Rejected(
                LifecycleRejection::StaleInstallation
            ))
        );
        drop(replacement);
        observations.drive(&mut core).unwrap();
        executor.drive(&mut core).unwrap();
        assert_eq!(polls.get(), 0);
        assert!(
            core.device_snapshot(&device())
                .unwrap()
                .binding_instance_id
                .is_none()
        );
    }
}

#[test]
fn activation_and_invalidation_state_events_bound_observations_in_sequence_order() {
    let (mut core, _, mut observations) = fixture(false, true);
    let subscription = core.open_event_subscription().unwrap();
    let s = source(vec![ObservationPoll::Observation(value())]);
    let polls = s.polls.clone();
    let proof = install(&mut core, &mut observations, "a", s);
    let pending = core.event_cursor();
    observations.drive(&mut core).unwrap();
    assert_eq!(polls.get(), 0);
    assert_eq!(core.event_cursor(), pending);
    core.activate_binding(proof, state(false, true)).unwrap();
    observations.drive(&mut core).unwrap();
    let mut events = vec![];
    while let EventPoll::Event(event) = core.poll_event(&subscription.token).unwrap() {
        events.push(event);
    }
    assert_eq!(events.len(), 3);
    assert!(
        matches!(&events[0], EdgeEvent::DeviceStateChanged(e) if e.device.availability == DeviceAvailability::Connecting)
    );
    let EdgeEvent::DeviceStateChanged(bound) = &events[1] else {
        panic!("binding state required")
    };
    let EdgeEvent::DeviceObservation(observed) = &events[2] else {
        panic!("observation required")
    };
    assert_eq!(
        bound.device.binding_instance_id.as_ref(),
        Some(&observed.binding_instance_id)
    );
    assert_eq!(bound.sequence.get() + 1, observed.sequence.get());
    let captured = value();
    let token = observations.publication_token(&device()).unwrap();
    core.invalidate_binding(&device(), &binding("a"), BindingInvalidation::Disconnected)
        .unwrap();
    let cursor = core.event_cursor();
    assert_eq!(
        core.publish_observation(&token, captured).unwrap(),
        ObservationDisposition::Fenced
    );
    assert_eq!(core.event_cursor(), cursor);
    assert!(
        matches!(core.poll_event(&subscription.token).unwrap(), EventPoll::Event(EdgeEvent::DeviceStateChanged(e)) if e.device.binding_instance_id.is_none())
    );
    assert_eq!(
        core.poll_event(&subscription.token).unwrap(),
        EventPoll::Empty
    );
}

#[test]
fn observation_uses_current_capability_and_revision_at_publication() {
    let (mut core, _, mut observations) = fixture(false, true);
    let proof = install(&mut core, &mut observations, "a", source(vec![]));
    core.activate_binding(proof, state(false, true)).unwrap();
    let token = observations.publication_token(&device()).unwrap();
    let captured = value();
    core.update_bound_device_state(&device(), &binding("a"), state(false, false))
        .unwrap();
    let cursor = core.event_cursor();
    assert_eq!(
        core.publish_observation(&token, captured).unwrap(),
        ObservationDisposition::CapabilityUnavailable
    );
    assert_eq!(core.event_cursor(), cursor);
    core.update_bound_device_state(&device(), &binding("a"), state(false, true))
        .unwrap();
    let subscription = core.open_event_subscription().unwrap();
    let revision = core.device_snapshot(&device()).unwrap().state_revision;
    core.publish_observation(&token, value()).unwrap();
    assert!(
        matches!(core.poll_event(&subscription.token).unwrap(), EventPoll::Event(EdgeEvent::DeviceObservation(e)) if e.state_revision == revision)
    );
    assert_eq!(
        core.device_snapshot(&device()).unwrap().state_revision,
        revision
    );
}

#[test]
fn queued_mixed_work_cannot_migrate_when_rebinding_precedes_executor_retirement() {
    let (mut core, mut executor, mut observations) = fixture_with_adapter(true, true);
    let old = RuntimeCounts::default();
    activate_mixed(
        &mut core,
        &mut executor,
        &mut observations,
        "a",
        HoldingAdapter {
            counts: old.clone(),
            possible: false,
            fault: false,
        },
        source(vec![ObservationPoll::ContinuityLost(
            AdapterErrorCode::new("sim.loss"),
        )]),
    );
    core.submit_command(command(false)).unwrap();
    observations.drive(&mut core).unwrap();
    // Install B while A's queued command still exists in the real executor queue.
    let replacement = RuntimeCounts::default();
    activate_mixed(
        &mut core,
        &mut executor,
        &mut observations,
        "b",
        HoldingAdapter {
            counts: replacement.clone(),
            possible: false,
            fault: false,
        },
        source(vec![]),
    );
    executor.drive(&mut core).unwrap();
    assert_eq!(old.begins.get(), 0);
    assert_eq!(replacement.begins.get(), 0);
    assert!(
        matches!(core.command_status(&CommandId::new("command").unwrap()),
        Some(CommandState::Terminal(t)) if t.outcome == TerminalOutcome::Failed && t.effect_evidence == EffectEvidence::None)
    );
    assert_eq!(
        core.device_snapshot(&device()).unwrap().binding_instance_id,
        Some(binding("b"))
    );
}

#[test]
fn retired_sources_never_poll_delayed_loss_or_panic_after_rebind() {
    for outcome in 0..=3 {
        let (mut core, _, mut old_supervisor) = fixture(false, true);
        let step = match outcome {
            0 => ObservationPoll::BindingLost(AdapterErrorCode::new("sim.lost")),
            1 => ObservationPoll::ContinuityLost(AdapterErrorCode::new("sim.loss")),
            _ => ObservationPoll::Observation(value()),
        };
        let mut old_source = source(vec![step]);
        old_source.panic = outcome == 3;
        let polls = old_source.polls.clone();
        let drops = old_source.drops.clone();
        let proof = install(&mut core, &mut old_supervisor, "a", old_source);
        core.activate_binding(proof, state(false, true)).unwrap();
        core.invalidate_binding(&device(), &binding("a"), BindingInvalidation::Disconnected)
            .unwrap();
        let mut replacement = ObservationSupervisor::new();
        let proof = install(&mut core, &mut replacement, "b", source(vec![]));
        core.activate_binding(proof, state(false, true)).unwrap();
        let snapshot = core.device_snapshot(&device()).unwrap().clone();
        let cursor = core.event_cursor();
        old_supervisor.drive(&mut core).unwrap();
        assert_eq!(polls.get(), 0);
        assert_eq!(drops.get(), 1);
        assert_eq!(core.event_cursor(), cursor);
        assert_eq!(core.device_snapshot(&device()), Some(&snapshot));
        assert!(old_supervisor.publication_token(&device()).is_none());
    }
}

#[test]
fn maximum_configured_sources_each_receive_one_poll_per_drive() {
    let agent = AgentInstanceId::new("agent").unwrap();
    let devices: Vec<_> = (0..32)
        .map(|i| DeviceId::new(format!("device-{i:02}")).unwrap())
        .collect();
    let seeds = devices
        .iter()
        .map(|device| CoreDeviceSeed {
            snapshot: DeviceSnapshot {
                agent_instance_id: agent.clone(),
                device_id: device.clone(),
                binding_instance_id: None,
                state_revision: StateRevision::new(0),
                adapter_kind: AdapterKind::new("synthetic").unwrap(),
                availability: DeviceAvailability::Absent,
                capabilities: BTreeSet::new(),
                conditions: BTreeSet::new(),
            },
            allowed_capabilities: vec![cap("scanner.barcode")],
            capability_resources: vec![],
        })
        .collect();
    let (producer, _consumer) = bounded_executor_queue::<Payload>([], 32, 32).unwrap();
    let mut core = CoreActor::new(
        agent,
        seeds,
        CoreLimits::with_registry_bounds(32, 32, 32, 32),
        Clock,
        producer,
    )
    .unwrap();
    let mut observations = ObservationSupervisor::new();
    let mut polls = vec![];
    for device in devices.iter().rev() {
        core.begin_connecting(device).unwrap();
        let source = source(vec![ObservationPoll::Observation(value()); 3]);
        polls.push(source.polls.clone());
        let proof = observations
            .install_binding(
                &mut core,
                device,
                &binding(device.as_str()),
                [cap("scanner.barcode")].into(),
                source,
            )
            .unwrap();
        core.activate_binding(proof, state(false, true)).unwrap();
    }
    let subscription = core.open_event_subscription().unwrap();
    observations.drive(&mut core).unwrap();
    assert!(polls.iter().all(|count| count.get() == 1));
    for device in devices {
        assert!(
            matches!(core.poll_event(&subscription.token).unwrap(), EventPoll::Event(EdgeEvent::DeviceObservation(e)) if e.device_id == device)
        );
    }
    assert_eq!(
        core.event_cursor().get(),
        subscription.snapshot.event_cursor.get() + 32
    );
    assert_eq!(
        core.poll_event(&subscription.token).unwrap(),
        EventPoll::Empty
    );
}

#[test]
fn unrepresentable_observation_is_fatal_without_sequence_or_truncation() {
    let agent = AgentInstanceId::new("agent").unwrap();
    let (producer, _consumer) = bounded_executor_queue::<Payload>([], 1, 1).unwrap();
    let mut limits = CoreLimits::with_registry_bounds(1, 1, 1, 1);
    limits.max_event_record_bytes = 1024; // deliberately below the production default
    let mut core = CoreActor::new(
        agent.clone(),
        vec![CoreDeviceSeed {
            snapshot: DeviceSnapshot {
                agent_instance_id: agent,
                device_id: device(),
                binding_instance_id: None,
                state_revision: StateRevision::new(0),
                adapter_kind: AdapterKind::new("synthetic").unwrap(),
                availability: DeviceAvailability::Absent,
                capabilities: BTreeSet::new(),
                conditions: BTreeSet::new(),
            },
            allowed_capabilities: vec![cap("scanner.barcode")],
            capability_resources: vec![],
        }],
        limits,
        Clock,
        producer,
    )
    .unwrap();
    let mut observations = ObservationSupervisor::new();
    let proof = install(&mut core, &mut observations, "a", source(vec![]));
    core.activate_binding(proof, state(false, true)).unwrap();
    let token = observations.publication_token(&device()).unwrap();
    let cursor = core.event_cursor();
    assert_eq!(
        core.publish_observation(
            &token,
            DeviceObservation::ScannerBarcode {
                barcode: BarcodeValue::new("x".repeat(4096)).unwrap(),
            }
        ),
        Err(CoreFatalError::EventNotRepresentable)
    );
    assert_eq!(core.event_cursor(), cursor);
    assert_eq!(
        core.publish_observation(&token, value()),
        Err(CoreFatalError::EventNotRepresentable)
    );
}

#[test]
fn containing_poll_and_prepared_runtime_debug_never_print_private_source_data() {
    #[derive(Debug)]
    struct PrivateSource(&'static str);
    impl ObservationSource for PrivateSource {
        fn poll(&mut self) -> ObservationPoll {
            ObservationPoll::Pending
        }
    }
    let sentinel = "PRIVATE_PREPARED_BARCODE";
    let source = PrivateSource(sentinel);
    assert!(format!("{source:?}").contains(source.0));
    let prepared = PreparedRuntime::<Adapter, _>::new(
        vec![],
        Some(([cap("scanner.barcode")].into(), source)),
        state(false, true),
    );
    assert!(!format!("{prepared:?}").contains(sentinel));
    let poll = ObservationPoll::Observation(DeviceObservation::ScannerBarcode {
        barcode: BarcodeValue::new(sentinel).unwrap(),
    });
    assert!(!format!("{poll:?}").contains(sentinel));
}
