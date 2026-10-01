use std::cell::{Cell, RefCell};
use std::collections::BTreeSet;
use std::rc::Rc;
use std::sync::{Arc, Weak};

use edge_adapter_api::{
    AdapterErrorCode, AdapterOperation, AdapterPoll, AdapterPollContext, DeviceAdapter, EffectClass,
};
use edge_core::*;
use edge_protocol::*;
use edge_sim::{Script, ScriptedAdapter, ScriptedOperation, SimProbe, Step};

const FAILURE: AdapterErrorCode = AdapterErrorCode::new("sim.synthetic_failure");

#[derive(Clone, Eq, PartialEq)]
struct Payload {
    resource: u8,
    marker: String,
    lifetime: Arc<()>,
}

impl TypedCommandPayload for Payload {
    fn command_kind(&self) -> &'static str {
        if self.resource == 7 {
            "synthetic.signal"
        } else {
            "synthetic.observe"
        }
    }
}

impl CoreCommand for Payload {
    type PayloadFingerprint = PrivateFingerprint;
    fn required_capability(&self) -> &'static str {
        self.command_kind()
    }

    fn effect_class(&self) -> EffectClass {
        EffectClass::DiscreteEffect
    }

    fn retained_payload_fingerprint(&self) -> PrivateFingerprint {
        PrivateFingerprint(self.resource, self.marker.clone())
    }
}

// Exact identity for the tiny synthetic value; no Debug/Display/Serialize.
#[derive(Clone, Eq, PartialEq)]
struct PrivateFingerprint(u8, String);

#[derive(Clone)]
struct Clock(Rc<Cell<u64>>);

impl AgentClock for Clock {
    fn now(&self) -> AgentUptimeMs {
        AgentUptimeMs::new(self.0.get())
    }
}

// The wrapper adds qualification observations without changing the simulator
// path or letting it reach Core. Weak references never retain sensitive data.
struct ObservedAdapter {
    inner: ScriptedAdapter,
    weak: Rc<RefCell<Vec<Weak<Payload>>>>,
}

impl DeviceAdapter<Payload> for ObservedAdapter {
    type Operation = ScriptedOperation<Payload>;
    fn begin(&mut self, payload: Arc<Payload>) -> Result<Self::Operation, AdapterErrorCode> {
        self.weak.borrow_mut().push(Arc::downgrade(&payload));
        self.inner.begin(payload)
    }
}

type Core = CoreActor<Payload, Clock, QueueProducer<Payload>>;

struct Fixture {
    core: Core,
    executor: ExecutorSupervisor<Payload, ObservedAdapter>,
    clock: Clock,
    probes: Vec<SimProbe>,
    weak: Rc<RefCell<Vec<Weak<Payload>>>>,
}

fn id(value: &str) -> CommandId {
    CommandId::new(value).unwrap()
}

fn device() -> DeviceId {
    DeviceId::new("synthetic.slot").unwrap()
}

fn binding() -> BindingInstanceId {
    BindingInstanceId::new("binding-a").unwrap()
}

fn seed() -> CoreDeviceSeed {
    CoreDeviceSeed {
        snapshot: DeviceSnapshot {
            agent_instance_id: AgentInstanceId::new("agent-a").unwrap(),
            device_id: device(),
            binding_instance_id: None,
            state_revision: StateRevision::new(0),
            adapter_kind: AdapterKind::new("synthetic").unwrap(),
            availability: DeviceAvailability::Absent,
            conditions: BTreeSet::new(),
            capabilities: BTreeSet::new(),
        },
        capability_resources: vec![
            (
                Capability::new("synthetic.signal").unwrap(),
                ResourceId::new(7),
            ),
            (
                Capability::new("synthetic.observe").unwrap(),
                ResourceId::new(9),
            ),
        ],
    }
}

fn command(name: &str, resource: u8, timeout: u64) -> CommandSubmission<Payload> {
    let payload = Payload {
        resource,
        marker: "SYNTHETIC_PAYLOAD_PRIVATE_SENTINEL".into(),
        lifetime: Arc::new(()),
    };
    CommandSubmission {
        request_id: RequestId::new("request-a").unwrap(),
        command_id: id(name),
        expected_agent_instance_id: AgentInstanceId::new("agent-a").unwrap(),
        device_id: device(),
        expected_binding_instance_id: binding(),
        not_after_agent_uptime_ms: AgentUptimeMs::new(160),
        kind: CommandKind::new(payload.command_kind()).unwrap(),
        timeout_ms: CommandTimeoutMs::new(timeout).unwrap(),
        payload,
    }
}

fn fixture(capacity: usize, scripts: [Vec<Vec<Step>>; 2]) -> Fixture {
    fixture_with_limits(
        capacity,
        scripts,
        CoreLimits::with_registry_bounds(1, 2, 2, 1),
    )
}

fn fixture_with_limits(
    capacity: usize,
    scripts: [Vec<Vec<Step>>; 2],
    limits: CoreLimits,
) -> Fixture {
    let clock = Clock(Rc::new(Cell::new(100)));
    let weak = Rc::new(RefCell::new(Vec::new()));
    let (producer, consumer) =
        bounded_executor_queue([ResourceId::new(7), ResourceId::new(9)], 2, capacity).unwrap();
    let mut probes = Vec::new();
    let adapters: Vec<_> = scripts
        .into_iter()
        .enumerate()
        .map(|(index, scripts)| {
            let (inner, probe) =
                ScriptedAdapter::new(scripts.into_iter().map(|v| Script::new(v).unwrap())).unwrap();
            probes.push(probe);
            (
                ResourceId::new(if index == 0 { 7 } else { 9 }),
                ObservedAdapter {
                    inner,
                    weak: weak.clone(),
                },
            )
        })
        .collect();
    let mut core = CoreActor::new(
        AgentInstanceId::new("agent-a").unwrap(),
        vec![seed()],
        limits,
        clock.clone(),
        producer,
    )
    .unwrap();
    let executor = make_executor(&mut core, consumer, adapters);
    Fixture {
        core,
        executor,
        clock,
        probes,
        weak,
    }
}

fn bound_state() -> BoundDeviceState {
    BoundDeviceState {
        availability: BoundAvailability::Degraded,
        conditions: BTreeSet::new(),
        capabilities: ["synthetic.signal", "synthetic.observe"]
            .into_iter()
            .map(|v| Capability::new(v).unwrap())
            .collect(),
    }
}

fn make_executor<A: DeviceAdapter<Payload>>(
    core: &mut Core,
    consumer: QueueConsumer<Payload>,
    adapters: impl IntoIterator<Item = (ResourceId, A)>,
) -> ExecutorSupervisor<Payload, A> {
    let mut executor = ExecutorSupervisor::new(consumer).unwrap();
    core.begin_connecting(&device()).unwrap();
    let witness = executor
        .install_binding(core, &device(), &binding(), adapters)
        .unwrap();
    core.activate_binding(witness, bound_state()).unwrap();
    executor
}

impl Fixture {
    fn submit(&mut self, name: &str, resource: u8, timeout: u64) {
        assert!(matches!(
            self.core
                .submit_command(command(name, resource, timeout))
                .unwrap(),
            AdmissionDecision::Accepted(CommandState::Accepted(_))
        ));
    }

    fn drive(&mut self) {
        self.executor.drive(&mut self.core).unwrap();
    }

    fn terminal(
        &self,
        name: &str,
        outcome: TerminalOutcome,
        evidence: EffectEvidence,
    ) -> TerminalCommandState {
        let Some(CommandState::Terminal(state)) = self.core.command_status(&id(name)) else {
            panic!("expected terminal");
        };
        assert_eq!(state.outcome, outcome);
        assert_eq!(state.effect_evidence, evidence);
        state
    }

    fn assert_fenced(&mut self) {
        assert_eq!(
            self.core.submit_command(command("new", 7, 100)).unwrap(),
            AdmissionDecision::Rejected(AdmissionRejection::BindingInstanceConflict)
        );
        assert!(self.core.command_status(&id("new")).is_none());
    }
}

#[test]
fn reservation_drop_capacity_and_consumer_shutdown_are_explicit() {
    assert_eq!(DEFAULT_WAITING_CAPACITY, 32);
    let (mut producer, consumer) =
        bounded_executor_queue::<Payload>([ResourceId::new(7)], 1, 2).unwrap();
    let a = producer.reserve(&ResourceId::new(7)).unwrap();
    let b = producer.reserve(&ResourceId::new(7)).unwrap();
    assert!(matches!(
        producer.reserve(&ResourceId::new(7)),
        Err(QueueReservationError::Full)
    ));
    drop(a);
    let c = producer.reserve(&ResourceId::new(7)).unwrap();
    drop(b);
    drop(c);
    drop(consumer);
    assert!(matches!(
        producer.reserve(&ResourceId::new(7)),
        Err(QueueReservationError::Unavailable)
    ));
}

#[test]
fn waiting_capacity_is_separate_from_active_and_fifo_never_overlaps() {
    let mut f = fixture(
        1,
        [
            vec![
                vec![Step::Pending, Step::CompleteFailed(FAILURE)],
                vec![Step::StallForever],
            ],
            vec![],
        ],
    );
    f.submit("a", 7, 100);
    assert_eq!(
        f.core.submit_command(command("b", 7, 100)).unwrap(),
        AdmissionDecision::Rejected(AdmissionRejection::ExecutorQueueFull)
    );
    assert_eq!(f.core.retained_command_count(), 1);
    assert!(f.core.command_status(&id("b")).is_none());
    f.drive(); // A promoted; waiting capacity restored.
    f.submit("b", 7, 100);
    f.drive(); // A pending, B still waiting.
    assert_eq!(f.probes[0].metrics().begins, 1);
    assert!(matches!(
        f.core.command_status(&id("b")),
        Some(CommandState::Accepted(_))
    ));
    f.drive(); // A fails known-none, B begins exactly once.
    f.terminal("a", TerminalOutcome::Failed, EffectEvidence::None);
    assert_eq!(f.probes[0].metrics().begins, 2);
    f.drive();
    assert_eq!(
        f.probes[0].metrics().last_recorded_command.as_deref(),
        Some("b")
    );
}

#[test]
fn independent_resources_and_stalls_do_bounded_work_per_drive() {
    let mut f = fixture(
        2,
        [
            vec![vec![Step::StallForever]],
            vec![vec![Step::StallForever]],
        ],
    );
    f.submit("a", 7, 100);
    f.submit("b", 9, 100);
    f.drive();
    for name in ["a", "b"] {
        assert!(matches!(
            f.core.command_status(&id(name)),
            Some(CommandState::Executing(_))
        ));
    }
    for expected in 1..=5 {
        f.drive();
        for probe in &f.probes {
            assert_eq!(probe.metrics().polls, expected);
        }
    }
}

#[test]
fn waiting_timeout_is_exact_and_removes_tail_without_invoking_adapter() {
    let mut f = fixture(
        4,
        [
            vec![vec![Step::StallForever], vec![Step::StallForever]],
            vec![],
        ],
    );
    f.submit("a", 7, 100);
    f.submit("b", 7, 100);
    f.submit("c", 7, 10);
    f.submit("d", 7, 100);
    f.drive();
    f.clock.0.set(109);
    f.drive();
    assert!(matches!(
        f.core.command_status(&id("c")),
        Some(CommandState::Accepted(_))
    ));
    f.clock.0.set(110);
    f.drive();
    f.terminal("c", TerminalOutcome::Failed, EffectEvidence::None);
    assert_eq!(f.probes[0].metrics().begins, 1);
    f.submit("e", 7, 100); // Queue timeout did not fence the binding.
    assert!(matches!(
        f.core.command_status(&id("b")),
        Some(CommandState::Accepted(_))
    ));
    assert!(matches!(
        f.core.command_status(&id("d")),
        Some(CommandState::Accepted(_))
    ));
}

#[test]
fn never_started_timeout_has_zero_adapter_invocations() {
    let mut f = fixture(1, [vec![], vec![]]);
    let request = command("a", 7, 10);
    let weak = Arc::downgrade(&request.payload.lifetime);
    assert!(matches!(
        f.core.submit_command(request).unwrap(),
        AdmissionDecision::Accepted(_)
    ));
    f.clock.0.set(110);
    f.drive();
    f.terminal("a", TerminalOutcome::Failed, EffectEvidence::None);
    assert_eq!(f.probes[0].metrics().begins, 0);
    assert!(weak.upgrade().is_none());
    f.submit("b", 7, 100);
}

#[test]
fn active_timeout_maps_each_evidence_and_stops_all_later_polls() {
    for (steps, expected) in [
        (
            vec![Step::StallForever],
            (TerminalOutcome::Failed, EffectEvidence::None),
        ),
        (
            vec![Step::MarkPossible, Step::StallForever],
            (TerminalOutcome::Unknown, EffectEvidence::Possible),
        ),
        (
            vec![Step::MarkPossible, Step::MarkConfirmed, Step::StallForever],
            (TerminalOutcome::Succeeded, EffectEvidence::Confirmed),
        ),
    ] {
        let mut f = fixture(1, [vec![steps.clone()], vec![]]);
        f.submit("a", 7, 10);
        f.drive();
        for _ in 0..steps.len() {
            f.drive();
        }
        f.clock.0.set(109);
        f.drive();
        assert!(matches!(
            f.core.command_status(&id("a")),
            Some(CommandState::Executing(_))
        ));
        f.clock.0.set(110);
        f.drive();
        f.terminal("a", expected.0, expected.1);
        let polls = f.probes[0].metrics().polls;
        for _ in 0..3 {
            f.drive();
        }
        assert_eq!(f.probes[0].metrics().polls, polls);
        assert_eq!(f.probes[0].metrics().operation_drops, 1);
        assert!(f.weak.borrow()[0].upgrade().is_none());
        f.assert_fenced();
    }
}

#[test]
fn panic_at_each_effect_stage_is_private_conservative_and_never_retried() {
    for (steps, expected) in [
        (
            vec![Step::Panic],
            (TerminalOutcome::Failed, EffectEvidence::None),
        ),
        (
            vec![Step::MarkPossible, Step::Panic],
            (TerminalOutcome::Unknown, EffectEvidence::Possible),
        ),
        (
            vec![Step::MarkPossible, Step::MarkConfirmed, Step::Panic],
            (TerminalOutcome::Succeeded, EffectEvidence::Confirmed),
        ),
    ] {
        let mut f = fixture(2, [vec![steps.clone()], vec![]]);
        f.submit("a", 7, 100);
        f.drive();
        for _ in &steps {
            f.drive();
        }
        let terminal = f.terminal("a", expected.0, expected.1);
        let diagnostics = format!("{terminal:?} {:?} {:?}", f.core, f.executor);
        assert!(!diagnostics.contains("SYNTHETIC_PAYLOAD_PRIVATE_SENTINEL"));
        assert!(!diagnostics.contains("SYNTHETIC_PANIC_PRIVATE_SENTINEL"));
        assert_eq!(terminal.error.unwrap().code.as_str(), "edge.adapter_panic");
        assert_eq!(f.probes[0].metrics().begins, 1);
        assert!(f.weak.borrow()[0].upgrade().is_none());
        assert!(matches!(
            f.core.submit_command(command("a", 7, 100)).unwrap(),
            AdmissionDecision::Deduplicated(_)
        ));
        f.assert_fenced();
    }
}

#[test]
fn normal_facts_and_contract_inconsistencies_derive_valid_pairs() {
    for (steps, expected, fenced) in [
        (
            vec![Step::CompleteRejected(FAILURE)],
            (TerminalOutcome::Rejected, EffectEvidence::None),
            false,
        ),
        (
            vec![Step::CompleteFailed(FAILURE)],
            (TerminalOutcome::Failed, EffectEvidence::None),
            false,
        ),
        (
            vec![Step::MarkPossible, Step::CompleteFailed(FAILURE)],
            (TerminalOutcome::Failed, EffectEvidence::Possible),
            false,
        ),
        (
            vec![
                Step::MarkPossible,
                Step::MarkConfirmed,
                Step::CompleteSuccess,
            ],
            (TerminalOutcome::Succeeded, EffectEvidence::Confirmed),
            false,
        ),
        (
            vec![Step::CompleteSuccess],
            (TerminalOutcome::Unknown, EffectEvidence::Possible),
            true,
        ),
        (
            vec![Step::MarkPossible, Step::CompleteSuccess],
            (TerminalOutcome::Unknown, EffectEvidence::Possible),
            true,
        ),
        (
            vec![Step::MarkPossible, Step::CompleteRejected(FAILURE)],
            (TerminalOutcome::Unknown, EffectEvidence::Possible),
            true,
        ),
        (
            vec![Step::MarkConfirmed],
            (TerminalOutcome::Unknown, EffectEvidence::Possible),
            true,
        ),
        (
            vec![
                Step::MarkPossible,
                Step::MarkConfirmed,
                Step::CompleteFailed(FAILURE),
            ],
            (TerminalOutcome::Succeeded, EffectEvidence::Confirmed),
            true,
        ),
        (
            vec![Step::BindingLost(FAILURE)],
            (TerminalOutcome::Failed, EffectEvidence::None),
            true,
        ),
        (
            vec![Step::MarkPossible, Step::BindingLost(FAILURE)],
            (TerminalOutcome::Unknown, EffectEvidence::Possible),
            true,
        ),
        (
            vec![
                Step::MarkPossible,
                Step::MarkConfirmed,
                Step::BindingLost(FAILURE),
            ],
            (TerminalOutcome::Succeeded, EffectEvidence::Confirmed),
            true,
        ),
    ] {
        let mut f = fixture(1, [vec![steps.clone()], vec![]]);
        f.submit("a", 7, 100);
        f.drive();
        for _ in &steps {
            f.drive();
        }
        let terminal = f.terminal("a", expected.0, expected.1);
        assert!(f.weak.borrow()[0].upgrade().is_none());
        assert_eq!(f.probes[0].metrics().begins, 1);
        let before = f.core.command_status(&id("a"));
        for _ in 0..2 {
            f.drive();
        }
        assert_eq!(before, f.core.command_status(&id("a"))); // immutable, no late script.
        assert_eq!(terminal.terminal_agent_uptime_ms.get(), 100);
        if fenced {
            f.assert_fenced();
        } else {
            f.submit("b", 7, 100);
        }
    }
}

#[test]
fn first_possible_effect_has_an_existing_executing_record() {
    let mut f = fixture(
        1,
        [
            vec![vec![
                Step::MarkPossible,
                Step::MarkConfirmed,
                Step::CompleteSuccess,
            ]],
            vec![],
        ],
    );
    f.submit("a", 7, 100);
    assert_eq!(f.core.retained_command_count(), 1);
    f.drive();
    f.drive();
    assert_eq!(f.probes[0].metrics().possible_marks, 1);
    assert_eq!(
        f.probes[0].metrics().last_recorded_command.as_deref(),
        Some("a")
    );
    assert!(matches!(
        f.core.command_status(&id("a")),
        Some(CommandState::Executing(_))
    ));
    f.drive();
    f.drive();
    f.terminal("a", TerminalOutcome::Succeeded, EffectEvidence::Confirmed);
}

#[test]
fn exact_epoch_fence_stops_queued_and_sibling_active_work() {
    let mut f = fixture(
        2,
        [
            vec![vec![Step::MarkPossible, Step::Panic]],
            vec![vec![Step::MarkPossible, Step::StallForever]],
        ],
    );
    f.submit("a", 7, 100);
    f.submit("b", 7, 100);
    f.submit("c", 9, 100);
    f.drive();
    f.drive();
    assert!(
        f.core
            .invalidate_binding(
                &device(),
                &BindingInstanceId::new("old-epoch").unwrap(),
                BindingInvalidation::ExecutionFault
            )
            .unwrap()
            == LifecycleChange::Stale
    );
    f.drive(); // A panic fences exact shared binding before C's next poll.
    f.terminal("a", TerminalOutcome::Unknown, EffectEvidence::Possible);
    f.terminal("b", TerminalOutcome::Failed, EffectEvidence::None);
    f.terminal("c", TerminalOutcome::Unknown, EffectEvidence::Possible);
    assert_eq!(f.probes[0].metrics().begins, 1);
    assert_eq!(f.probes[1].metrics().polls, 1);
    for weak in f.weak.borrow().iter() {
        assert!(weak.upgrade().is_none());
    }
    f.assert_fenced();
}

#[test]
fn externally_fenced_waiting_work_never_begins() {
    let mut f = fixture(1, [vec![], vec![]]);
    f.submit("a", 7, 100);
    assert_eq!(
        f.core
            .invalidate_binding(&device(), &binding(), BindingInvalidation::ExecutionFault)
            .unwrap(),
        LifecycleChange::Changed
    );
    f.drive();
    f.terminal("a", TerminalOutcome::Failed, EffectEvidence::None);
    assert_eq!(f.probes[0].metrics().begins, 0);
}

#[test]
fn execution_clock_regression_is_fatal_and_poisoned_drive_never_polls() {
    let mut f = fixture(1, [vec![vec![Step::StallForever]], vec![]]);
    f.submit("a", 7, 100);
    f.drive();
    f.clock.0.set(99);
    assert_eq!(
        f.executor.drive(&mut f.core),
        Err(CoreFatalError::ClockRegression)
    );
    f.clock.0.set(101);
    assert_eq!(
        f.executor.drive(&mut f.core),
        Err(CoreFatalError::ExecutionInvariant)
    );
    assert_eq!(f.probes[0].metrics().polls, 0);
}

#[test]
fn execution_timeout_near_u64_max_uses_elapsed_subtraction() {
    let mut f = fixture(1, [vec![vec![Step::StallForever]], vec![]]);
    f.clock.0.set(u64::MAX - 4);
    let mut request = command("a", 7, 4);
    request.not_after_agent_uptime_ms = AgentUptimeMs::new(u64::MAX);
    assert!(matches!(
        f.core.submit_command(request).unwrap(),
        AdmissionDecision::Accepted(_)
    ));
    f.drive();
    f.clock.0.set(u64::MAX - 1);
    f.drive();
    f.clock.0.set(u64::MAX);
    f.drive();
    f.terminal("a", TerminalOutcome::Failed, EffectEvidence::None);
}

#[test]
fn simulator_script_bounds_are_enforced_before_growth() {
    assert!(matches!(Script::new([]), Err(edge_sim::ScriptError::Empty)));
    assert!(
        Script::new(std::iter::repeat_n(
            Step::Pending,
            edge_sim::MAX_SCRIPT_STEPS
        ))
        .is_ok()
    );
    assert!(matches!(
        Script::new(std::iter::repeat_n(
            Step::Pending,
            edge_sim::MAX_SCRIPT_STEPS + 1
        )),
        Err(edge_sim::ScriptError::TooManySteps)
    ));
    assert!(matches!(
        ScriptedAdapter::new(
            (0..=edge_sim::MAX_ADAPTER_SCRIPTS).map(|_| Script::new([Step::Pending]).unwrap())
        ),
        Err(edge_sim::ScriptError::TooManyScripts)
    ));
}

#[test]
fn adapter_panic_hook_redacts_payload_and_preserves_non_adapter_hook() {
    // A subprocess isolates global hook installation from parallel tests and
    // observes stderr, not just the returned command error.
    if std::env::var_os("M824_PANIC_PROBE_CHILD").is_some() {
        std::panic::set_hook(Box::new(|info| eprintln!("prior hook: {info}")));
        let mut f = fixture(1, [vec![vec![Step::Panic]], vec![]]);
        // Construction must not chain another privacy wrapper or lose the
        // captured application hook.
        let _second = fixture(1, [vec![], vec![]]);
        f.submit("a", 7, 100);
        f.drive();
        f.drive();
        f.terminal("a", TerminalOutcome::Failed, EffectEvidence::None);
        let _ = std::panic::catch_unwind(|| panic!("normal hook preserved"));
        return;
    }
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "adapter_panic_hook_redacts_payload_and_preserves_non_adapter_hook",
            "--nocapture",
        ])
        .env("M824_PANIC_PROBE_CHILD", "1")
        .output()
        .unwrap();
    assert!(output.status.success());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(!stderr.contains("SYNTHETIC_PANIC_PRIVATE_SENTINEL"));
    assert!(stderr.contains("normal hook preserved"));
    assert_eq!(stderr.matches("prior hook:").count(), 1);
}

struct SpecialAdapter {
    clock: Clock,
    panic_begin: bool,
    panic_drop: bool,
    advance_during_poll: Option<u64>,
    advance_during_begin: Option<u64>,
    weak: Rc<RefCell<Option<Weak<Payload>>>>,
    polls: Rc<Cell<usize>>,
}

struct SpecialOperation {
    _payload: Arc<Payload>,
    clock: Clock,
    panic_drop: bool,
    advance_during_poll: Option<u64>,
    polls: Rc<Cell<usize>>,
}

impl DeviceAdapter<Payload> for SpecialAdapter {
    type Operation = SpecialOperation;
    fn begin(&mut self, payload: Arc<Payload>) -> Result<Self::Operation, AdapterErrorCode> {
        *self.weak.borrow_mut() = Some(Arc::downgrade(&payload));
        if self.panic_begin {
            std::panic::panic_any("SYNTHETIC_BEGIN_PRIVATE_SENTINEL");
        }
        if let Some(now) = self.advance_during_begin {
            self.clock.0.set(now);
        }
        Ok(SpecialOperation {
            _payload: payload,
            clock: self.clock.clone(),
            panic_drop: self.panic_drop,
            advance_during_poll: self.advance_during_poll,
            polls: self.polls.clone(),
        })
    }
}

impl AdapterOperation for SpecialOperation {
    fn poll(&mut self, context: &mut AdapterPollContext<'_>) -> AdapterPoll {
        self.polls.set(self.polls.get() + 1);
        context.effects.mark_possible();
        if let Some(now) = self.advance_during_poll {
            self.clock.0.set(now);
        }
        if self.panic_drop {
            AdapterPoll::KnownFailure(FAILURE)
        } else {
            AdapterPoll::Pending
        }
    }
}

impl Drop for SpecialOperation {
    fn drop(&mut self) {
        if self.panic_drop {
            std::panic::panic_any("SYNTHETIC_DROP_PRIVATE_SENTINEL");
        }
    }
}

#[test]
fn begin_panic_is_contained_and_releases_payload() {
    let clock = Clock(Rc::new(Cell::new(100)));
    let weak = Rc::new(RefCell::new(None));
    let polls = Rc::new(Cell::new(0));
    let (producer, consumer) =
        bounded_executor_queue([ResourceId::new(7), ResourceId::new(9)], 2, 1).unwrap();
    let adapters = [7, 9].map(|resource| {
        (
            ResourceId::new(resource),
            SpecialAdapter {
                clock: clock.clone(),
                panic_begin: true,
                panic_drop: false,
                advance_during_poll: None,
                advance_during_begin: None,
                weak: weak.clone(),
                polls: polls.clone(),
            },
        )
    });

    let mut core = CoreActor::new(
        AgentInstanceId::new("agent-a").unwrap(),
        vec![seed()],
        CoreLimits::with_registry_bounds(1, 2, 2, 1),
        clock.clone(),
        producer,
    )
    .unwrap();
    let mut executor = make_executor(&mut core, consumer, adapters);
    core.submit_command(command("a", 7, 10)).unwrap();
    executor.drive(&mut core).unwrap();
    let Some(CommandState::Terminal(terminal)) = core.command_status(&id("a")) else {
        panic!("expected terminal");
    };
    assert_eq!(
        (terminal.outcome, terminal.effect_evidence),
        (TerminalOutcome::Failed, EffectEvidence::None)
    );
    assert_eq!(terminal.error.unwrap().code.as_str(), "edge.adapter_panic");
    assert!(weak.borrow().as_ref().unwrap().upgrade().is_none());
    assert_eq!(polls.get(), 0); // begin has no effect handle and performs no I/O.
    assert_eq!(
        core.submit_command(command("b", 7, 10)).unwrap(),
        AdmissionDecision::Rejected(AdmissionRejection::BindingInstanceConflict)
    );
}

#[test]
fn deadline_or_clock_regression_during_poll_is_observed_before_result() {
    for next_time in [110, 99] {
        let clock = Clock(Rc::new(Cell::new(100)));
        let weak = Rc::new(RefCell::new(None));
        let polls = Rc::new(Cell::new(0));
        let (producer, consumer) =
            bounded_executor_queue([ResourceId::new(7), ResourceId::new(9)], 2, 1).unwrap();
        let adapters = [7, 9].map(|r| {
            (
                ResourceId::new(r),
                SpecialAdapter {
                    clock: clock.clone(),
                    panic_begin: false,
                    panic_drop: false,
                    advance_during_poll: Some(next_time),
                    advance_during_begin: None,
                    weak: weak.clone(),
                    polls: polls.clone(),
                },
            )
        });

        let mut core = CoreActor::new(
            AgentInstanceId::new("agent-a").unwrap(),
            vec![seed()],
            CoreLimits::with_registry_bounds(1, 2, 2, 1),
            clock.clone(),
            producer,
        )
        .unwrap();
        let mut executor = make_executor(&mut core, consumer, adapters);
        core.submit_command(command("a", 7, 10)).unwrap();
        executor.drive(&mut core).unwrap();
        if next_time == 99 {
            assert_eq!(
                executor.drive(&mut core),
                Err(CoreFatalError::ClockRegression)
            );
            // Active::Drop runs even on this fatal early-return path.
            assert!(weak.borrow().as_ref().unwrap().upgrade().is_some()); // Core still owns nonterminal payload until epoch disposal.
            drop(core);
            drop(executor);
            assert!(weak.borrow().as_ref().unwrap().upgrade().is_none());
        } else {
            executor.drive(&mut core).unwrap();
            let Some(CommandState::Terminal(terminal)) = core.command_status(&id("a")) else {
                panic!("expected timeout");
            };
            assert_eq!(
                (terminal.outcome, terminal.effect_evidence),
                (TerminalOutcome::Unknown, EffectEvidence::Possible)
            );
            assert_eq!(terminal.terminal_agent_uptime_ms.get(), 110);
            assert!(weak.borrow().as_ref().unwrap().upgrade().is_none());
        }
        assert_eq!(polls.get(), 1);
    }
}

#[test]
fn begin_consuming_the_timeout_is_fenced_before_drive_returns() {
    let clock = Clock(Rc::new(Cell::new(100)));
    let weak = Rc::new(RefCell::new(None));
    let polls = Rc::new(Cell::new(0));
    let (producer, consumer) =
        bounded_executor_queue([ResourceId::new(7), ResourceId::new(9)], 2, 1).unwrap();
    let adapters = [7, 9].map(|r| {
        (
            ResourceId::new(r),
            SpecialAdapter {
                clock: clock.clone(),
                panic_begin: false,
                panic_drop: false,
                advance_during_poll: None,
                advance_during_begin: Some(110),
                weak: weak.clone(),
                polls: polls.clone(),
            },
        )
    });

    let mut core = CoreActor::new(
        AgentInstanceId::new("agent-a").unwrap(),
        vec![seed()],
        CoreLimits::with_registry_bounds(1, 2, 2, 1),
        clock.clone(),
        producer,
    )
    .unwrap();
    let mut executor = make_executor(&mut core, consumer, adapters);
    core.submit_command(command("a", 7, 10)).unwrap();
    executor.drive(&mut core).unwrap();
    let Some(CommandState::Terminal(terminal)) = core.command_status(&id("a")) else {
        panic!("expected timeout at end of begin");
    };
    assert_eq!(
        (terminal.outcome, terminal.effect_evidence),
        (TerminalOutcome::Failed, EffectEvidence::None)
    );
    assert!(weak.borrow().as_ref().unwrap().upgrade().is_none());
    assert_eq!(polls.get(), 0);
    assert_eq!(
        core.submit_command(command("b", 7, 10)).unwrap(),
        AdmissionDecision::Rejected(AdmissionRejection::BindingInstanceConflict)
    );
}

struct CleanupWitnessAdapter {
    clock: Clock,
    dropped_at: Rc<Cell<Option<u64>>>,
    polls: Rc<Cell<usize>>,
}

struct CleanupWitnessOperation {
    clock: Clock,
    dropped_at: Rc<Cell<Option<u64>>>,
    polls: Rc<Cell<usize>>,
    _payload: Arc<Payload>,
}

impl DeviceAdapter<Payload> for CleanupWitnessAdapter {
    type Operation = CleanupWitnessOperation;
    fn begin(&mut self, payload: Arc<Payload>) -> Result<Self::Operation, AdapterErrorCode> {
        Ok(CleanupWitnessOperation {
            clock: self.clock.clone(),
            dropped_at: self.dropped_at.clone(),
            polls: self.polls.clone(),
            _payload: payload,
        })
    }
}

impl AdapterOperation for CleanupWitnessOperation {
    fn poll(&mut self, _: &mut AdapterPollContext<'_>) -> AdapterPoll {
        self.polls.set(self.polls.get() + 1);
        AdapterPoll::Pending
    }
}

impl Drop for CleanupWitnessOperation {
    fn drop(&mut self) {
        self.dropped_at.set(Some(self.clock.0.get()));
        // Model bounded cleanup consuming time without initiating an effect.
        self.clock.0.set(111);
    }
}

#[test]
fn timeout_cleanup_precedes_terminal_timestamp_and_stops_polls() {
    let clock = Clock(Rc::new(Cell::new(100)));
    let dropped_at = Rc::new(Cell::new(None));
    let polls = Rc::new(Cell::new(0));
    let (producer, consumer) =
        bounded_executor_queue([ResourceId::new(7), ResourceId::new(9)], 2, 1).unwrap();

    let mut core = CoreActor::new(
        AgentInstanceId::new("agent-a").unwrap(),
        vec![seed()],
        CoreLimits::with_registry_bounds(1, 2, 2, 1),
        clock.clone(),
        producer,
    )
    .unwrap();
    let mut executor = make_executor(
        &mut core,
        consumer,
        [7, 9].map(|r| {
            (
                ResourceId::new(r),
                CleanupWitnessAdapter {
                    clock: clock.clone(),
                    dropped_at: dropped_at.clone(),
                    polls: polls.clone(),
                },
            )
        }),
    );
    let request = command("a", 7, 10);
    let weak = Arc::downgrade(&request.payload.lifetime);
    core.submit_command(request).unwrap();
    executor.drive(&mut core).unwrap();
    executor.drive(&mut core).unwrap();
    clock.0.set(110);
    executor.drive(&mut core).unwrap();
    let Some(CommandState::Terminal(terminal)) = core.command_status(&id("a")) else {
        panic!("expected terminal after cleanup");
    };
    assert_eq!(dropped_at.get(), Some(110));
    assert_eq!(terminal.terminal_agent_uptime_ms.get(), 111);
    assert_eq!(
        (terminal.outcome, terminal.effect_evidence),
        (TerminalOutcome::Failed, EffectEvidence::None)
    );
    assert!(weak.upgrade().is_none());
    executor.drive(&mut core).unwrap();
    assert_eq!(polls.get(), 1);
}

struct PanickingAdapterDrop(bool);

struct UnmarkedSuccessAtDeadline(Clock);

impl DeviceAdapter<Payload> for UnmarkedSuccessAtDeadline {
    type Operation = Self;
    fn begin(&mut self, _: Arc<Payload>) -> Result<Self::Operation, AdapterErrorCode> {
        Ok(Self(self.0.clone()))
    }
}

impl AdapterOperation for UnmarkedSuccessAtDeadline {
    fn poll(&mut self, _: &mut AdapterPollContext<'_>) -> AdapterPoll {
        self.0.0.set(110);
        // Contradictory claimed success must undermine None even if this poll
        // also consumes the deadline. Timeout must not hide the violation.
        AdapterPoll::Succeeded
    }
}

#[test]
fn unmarked_success_at_deadline_never_claims_known_non_effect() {
    let clock = Clock(Rc::new(Cell::new(100)));
    let (producer, consumer) =
        bounded_executor_queue([ResourceId::new(7), ResourceId::new(9)], 2, 1).unwrap();

    let mut core = CoreActor::new(
        AgentInstanceId::new("agent-a").unwrap(),
        vec![seed()],
        CoreLimits::with_registry_bounds(1, 2, 2, 1),
        clock.clone(),
        producer,
    )
    .unwrap();
    let mut executor = make_executor(
        &mut core,
        consumer,
        [7, 9].map(|r| (ResourceId::new(r), UnmarkedSuccessAtDeadline(clock.clone()))),
    );
    core.submit_command(command("a", 7, 10)).unwrap();
    executor.drive(&mut core).unwrap();
    executor.drive(&mut core).unwrap();
    let Some(CommandState::Terminal(terminal)) = core.command_status(&id("a")) else {
        panic!("expected terminal");
    };
    assert_eq!(
        (terminal.outcome, terminal.effect_evidence),
        (TerminalOutcome::Unknown, EffectEvidence::Possible)
    );
    assert_eq!(
        core.submit_command(command("b", 7, 10)).unwrap(),
        AdmissionDecision::Rejected(AdmissionRejection::BindingInstanceConflict)
    );
}

impl DeviceAdapter<Payload> for PanickingAdapterDrop {
    type Operation = ScriptedOperation<Payload>;
    fn begin(&mut self, _: Arc<Payload>) -> Result<Self::Operation, AdapterErrorCode> {
        Err(FAILURE)
    }
}

impl Drop for PanickingAdapterDrop {
    fn drop(&mut self) {
        if self.0 {
            std::panic::panic_any("SYNTHETIC_ADAPTER_DROP_PRIVATE_SENTINEL");
        }
    }
}

#[test]
fn destructor_panic_requires_process_termination_before_terminal_publication() {
    if let Some(mode) = std::env::var_os("M824_DESTRUCTOR_PROBE_CHILD") {
        if mode == "adapter" || mode == "unconsumed" {
            let (producer, consumer) =
                bounded_executor_queue::<Payload>([ResourceId::new(7)], 1, 1).unwrap();
            let seeds = if mode == "adapter" {
                vec![(ResourceId::new(9), PanickingAdapterDrop(true))]
            } else {
                // Early rejection leaves this iterator owning another adapter.
                vec![
                    (ResourceId::new(9), PanickingAdapterDrop(false)),
                    (ResourceId::new(7), PanickingAdapterDrop(true)),
                ]
            };
            let mut core = CoreActor::new(
                AgentInstanceId::new("agent-a").unwrap(),
                vec![seed()],
                CoreLimits::with_registry_bounds(1, 2, 2, 1),
                Clock(Rc::new(Cell::new(100))),
                producer,
            )
            .unwrap();
            core.begin_connecting(&device()).unwrap();
            let mut executor = ExecutorSupervisor::new(consumer).unwrap();
            let _ = executor.install_binding(&mut core, &device(), &binding(), seeds);
        } else {
            let clock = Clock(Rc::new(Cell::new(100)));
            let (producer, consumer) =
                bounded_executor_queue([ResourceId::new(7), ResourceId::new(9)], 2, 1).unwrap();
            let adapters = [7, 9].map(|resource| {
                (
                    ResourceId::new(resource),
                    SpecialAdapter {
                        clock: clock.clone(),
                        panic_begin: false,
                        panic_drop: true,
                        advance_during_poll: None,
                        advance_during_begin: None,
                        weak: Rc::new(RefCell::new(None)),
                        polls: Rc::new(Cell::new(0)),
                    },
                )
            });

            let mut core = CoreActor::new(
                AgentInstanceId::new("agent-a").unwrap(),
                vec![seed()],
                CoreLimits::with_registry_bounds(1, 2, 2, 1),
                clock,
                producer,
            )
            .unwrap();
            let mut executor = make_executor(&mut core, consumer, adapters);
            core.submit_command(command("a", 7, 10)).unwrap();
            executor.drive(&mut core).unwrap();
            executor.drive(&mut core).unwrap();
        }
        // Returning here would wrongly allow the same epoch to continue after
        // cleanup failed to establish the no-future-I/O guarantee.
        return;
    }
    for mode in ["operation", "adapter", "unconsumed"] {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "destructor_panic_requires_process_termination_before_terminal_publication",
                "--nocapture",
            ])
            .env("M824_DESTRUCTOR_PROBE_CHILD", mode)
            .current_dir(std::env::temp_dir())
            .output()
            .unwrap();
        assert!(
            !output.status.success(),
            "{mode} destructor panic was swallowed"
        );
        #[cfg(unix)]
        {
            use std::os::unix::process::ExitStatusExt;
            // SIGABRT, rather than an unrelated failed assertion in the child.
            assert_eq!(output.status.signal(), Some(6));
        }
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(!stderr.contains("PRIVATE_SENTINEL"));
    }
}

#[path = "execution/lifecycle_events.rs"]
mod lifecycle_events;

#[path = "execution/qualification.rs"]
mod qualification;
