use std::cell::Cell;
use std::collections::BTreeSet;
use std::rc::Rc;
use std::sync::{Arc, Weak};

use edge_protocol::{
    AdapterKind, AgentInstanceId, BindingInstanceId, CommandKind, CommandTimeoutMs,
    DeviceAvailability, EffectEvidence, RequestId, StateRevision, TypedCommandPayload,
};

use super::*;
use crate::{QueueCommitError, QueueReservationError};

#[derive(Clone)]
struct FakeClock(Rc<Cell<u64>>);

impl FakeClock {
    fn new(now: u64) -> Self {
        Self(Rc::new(Cell::new(now)))
    }

    fn set(&self, now: u64) {
        self.0.set(now);
    }
}

impl AgentClock for FakeClock {
    fn now(&self) -> AgentUptimeMs {
        AgentUptimeMs::new(self.0.get())
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum SyntheticKind {
    Observe,
    Signal,
}

#[derive(Clone, Eq, PartialEq)]
struct SyntheticCommand {
    variant: SyntheticKind,
    marker: String,
}

impl TypedCommandPayload for SyntheticCommand {
    fn command_kind(&self) -> &'static str {
        match self.variant {
            SyntheticKind::Observe => "synthetic.observe",
            SyntheticKind::Signal => "synthetic.signal",
        }
    }
}

// Kind is already a separate identity dimension, so this exact synthetic
// payload identity carries only the marker. It has no Debug/Display/Serialize
// implementation and must never reach public status.
#[derive(Clone, Eq, PartialEq)]
struct PrivateFingerprint(String);

impl CoreCommand for SyntheticCommand {
    type PayloadFingerprint = PrivateFingerprint;

    fn required_capability(&self) -> &'static str {
        self.command_kind()
    }

    fn retained_payload_fingerprint(&self) -> Self::PayloadFingerprint {
        PrivateFingerprint(self.marker.clone())
    }
}

#[derive(Default)]
struct FakeQueue {
    reserve_calls: usize,
    reserved_resources: Vec<ResourceId>,
    commit_calls: usize,
    committed: Vec<CommandId>,
    witness_seen: bool,
    recorded_address_at_commit: Option<usize>,
    queued_debug: Option<String>,
    fail_reserve: Option<QueueReservationError>,
    fail_commit: bool,
    outstanding_reservations: Rc<Cell<usize>>,
}

struct FakeReservation {
    outstanding: Rc<Cell<usize>>,
}

impl Drop for FakeReservation {
    fn drop(&mut self) {
        self.outstanding.set(self.outstanding.get() - 1);
    }
}

impl ExecutorQueuePort<SyntheticCommand> for FakeQueue {
    type Reservation = FakeReservation;

    fn reserve(
        &mut self,
        resource: &ResourceId,
    ) -> Result<Self::Reservation, QueueReservationError> {
        self.reserve_calls += 1;
        self.reserved_resources.push(*resource);
        if let Some(error) = self.fail_reserve {
            return Err(error);
        }
        self.outstanding_reservations
            .set(self.outstanding_reservations.get() + 1);
        Ok(FakeReservation {
            outstanding: Rc::clone(&self.outstanding_reservations),
        })
    }

    fn commit(
        &mut self,
        _reservation: Self::Reservation,
        command: QueuedCommand<SyntheticCommand>,
        recorded: &NonterminalCommandState,
    ) -> Result<(), QueueCommitError> {
        self.commit_calls += 1;
        assert_eq!(&recorded.command_id, command.command_id());
        assert_eq!(&recorded.device_id, command.device_id());
        assert_eq!(
            recorded.accepted_agent_uptime_ms,
            command.accepted_agent_uptime_ms()
        );
        self.witness_seen = true;
        self.recorded_address_at_commit = Some(std::ptr::from_ref(recorded) as usize);
        self.queued_debug = Some(format!("{command:?}"));
        if self.fail_commit {
            return Err(QueueCommitError::GuaranteedNotEnqueued);
        }
        self.committed.push(command.command_id().clone());
        // This fake consumes/drops its queued payload without physical effects.
        Ok(())
    }
}

type TestCore = CoreActor<SyntheticCommand, FakeClock, FakeQueue>;

fn agent() -> AgentInstanceId {
    AgentInstanceId::new("agent-a").unwrap()
}

fn device_id(value: &str) -> DeviceId {
    DeviceId::new(value).unwrap()
}

fn binding(value: &str) -> BindingInstanceId {
    BindingInstanceId::new(value).unwrap()
}

fn capability(value: &str) -> Capability {
    Capability::new(value).unwrap()
}

fn limits() -> CoreLimits {
    let mut limits = CoreLimits::with_registry_bounds(2, 2, 3, 3);
    limits.max_command_records = 3;
    limits.max_submission_horizon_ms = 10;
    limits.max_command_timeout_ms = 10;
    limits.terminal_recovery_minimum_ms = 5;
    limits
}

fn seed(
    id: &str,
    binding_id: Option<&str>,
    availability: DeviceAvailability,
    caps: &[&str],
    mappings: &[(&str, ResourceId)],
) -> CoreDeviceSeed {
    CoreDeviceSeed {
        snapshot: DeviceSnapshot {
            agent_instance_id: agent(),
            device_id: device_id(id),
            binding_instance_id: binding_id.map(binding),
            state_revision: StateRevision::new(0),
            adapter_kind: AdapterKind::new("synthetic").unwrap(),
            availability,
            conditions: BTreeSet::new(),
            capabilities: caps.iter().map(|cap| capability(cap)).collect(),
        },
        capability_resources: mappings
            .iter()
            .map(|(cap, resource)| (capability(cap), *resource))
            .collect(),
    }
}

fn normal_seed() -> CoreDeviceSeed {
    seed(
        "lane-a.device",
        Some("binding-a"),
        DeviceAvailability::Ready,
        &["synthetic.observe", "synthetic.signal"],
        &[
            ("synthetic.observe", ResourceId::new(7)),
            ("synthetic.signal", ResourceId::new(7)),
        ],
    )
}

fn core(clock: FakeClock, limits: CoreLimits, queue: FakeQueue) -> TestCore {
    TestCore::new(agent(), vec![normal_seed()], limits, clock, queue).unwrap()
}

fn command(
    id: &str,
    request: &str,
    deadline: u64,
    timeout: u64,
) -> CommandSubmission<SyntheticCommand> {
    CommandSubmission {
        request_id: RequestId::new(request).unwrap(),
        command_id: CommandId::new(id).unwrap(),
        expected_agent_instance_id: agent(),
        device_id: device_id("lane-a.device"),
        expected_binding_instance_id: binding("binding-a"),
        not_after_agent_uptime_ms: AgentUptimeMs::new(deadline),
        kind: CommandKind::new("synthetic.observe").unwrap(),
        timeout_ms: CommandTimeoutMs::new(timeout).unwrap(),
        payload: SyntheticCommand {
            variant: SyntheticKind::Observe,
            marker: "harmless".to_owned(),
        },
    }
}

fn accepted(decision: AdmissionDecision) -> CommandState {
    match decision {
        AdmissionDecision::Accepted(state) => state,
        other => panic!("expected accepted command, got {other:?}"),
    }
}

fn rejected(decision: AdmissionDecision) -> AdmissionRejection {
    match decision {
        AdmissionDecision::Rejected(reason) => reason,
        other => panic!("expected rejection, got {other:?}"),
    }
}

fn terminate_without_effect(core: &mut TestCore, clock: &FakeClock, id: &str, at: u64) {
    clock.set(at);
    let now = core.observe_uptime().unwrap();
    core.terminalize_non_effect(&CommandId::new(id).unwrap(), now)
        .unwrap();
}

#[test]
fn defaults_and_registry_seed_are_bounded_and_consistent() {
    let defaults = CoreLimits::with_registry_bounds(2, 2, 3, 3);
    assert_eq!(defaults.max_command_records, 4096);
    assert_eq!(defaults.max_submission_horizon_ms, 60_000);
    assert_eq!(defaults.max_command_timeout_ms, 60_000);
    assert_eq!(defaults.terminal_recovery_minimum_ms, 120_000);

    let make = |seeds, limits| {
        TestCore::new(
            agent(),
            seeds,
            limits,
            FakeClock::new(0),
            FakeQueue::default(),
        )
    };
    assert_eq!(
        make(vec![normal_seed(), normal_seed()], limits()).unwrap_err(),
        CoreFatalError::DuplicateDevice
    );
    let mut wrong_agent = normal_seed();
    wrong_agent.snapshot.agent_instance_id = AgentInstanceId::new("agent-b").unwrap();
    assert_eq!(
        make(vec![wrong_agent], limits()).unwrap_err(),
        CoreFatalError::RegistryAgentMismatch
    );
    let unpublished = seed(
        "lane-a.device",
        Some("binding-a"),
        DeviceAvailability::Ready,
        &[],
        &[("synthetic.observe", ResourceId::new(7))],
    );
    assert_eq!(
        make(vec![unpublished], limits()).unwrap_err(),
        CoreFatalError::UnpublishedResourceMapping
    );
    let duplicate_mapping = seed(
        "lane-a.device",
        Some("binding-a"),
        DeviceAvailability::Ready,
        &["synthetic.observe"],
        &[
            ("synthetic.observe", ResourceId::new(7)),
            ("synthetic.observe", ResourceId::new(8)),
        ],
    );
    assert_eq!(
        make(vec![duplicate_mapping], limits()).unwrap_err(),
        CoreFatalError::DuplicateResourceMapping
    );
    let unbound = seed(
        "lane-a.device",
        None,
        DeviceAvailability::Absent,
        &["synthetic.observe"],
        &[("synthetic.observe", ResourceId::new(7))],
    );
    assert_eq!(
        make(vec![unbound], limits()).unwrap_err(),
        CoreFatalError::UnboundResourceMapping
    );
    let second = seed(
        "lane-b.device",
        Some("binding-b"),
        DeviceAvailability::Ready,
        &["synthetic.observe"],
        &[("synthetic.observe", ResourceId::new(7))],
    );
    assert_eq!(
        make(vec![normal_seed(), second], limits()).unwrap_err(),
        CoreFatalError::ResourceSharedAcrossDevices
    );
    let mut tiny = limits();
    tiny.max_devices = 1;
    assert_eq!(
        make(vec![normal_seed(), normal_seed()], tiny).unwrap_err(),
        CoreFatalError::TooManyDevices
    );
    let mut tiny = limits();
    tiny.max_resources = 1;
    let two_resources = seed(
        "lane-a.device",
        Some("binding-a"),
        DeviceAvailability::Ready,
        &["synthetic.observe", "synthetic.signal"],
        &[
            ("synthetic.observe", ResourceId::new(7)),
            ("synthetic.signal", ResourceId::new(8)),
        ],
    );
    assert_eq!(
        make(vec![two_resources], tiny).unwrap_err(),
        CoreFatalError::TooManyResources
    );
}

#[test]
fn agent_precondition_and_retained_identity_win_before_current_state() {
    let clock = FakeClock::new(100);
    let mut core = core(clock.clone(), limits(), FakeQueue::default());
    let original = command("same", "request-a", 105, 10);
    accepted(core.submit_command(original.clone()).unwrap());
    assert_eq!(core.queue.reserve_calls, 1);
    let mut wrong_agent = original.clone();
    wrong_agent.expected_agent_instance_id = AgentInstanceId::new("agent-b").unwrap();
    wrong_agent.kind = CommandKind::new("synthetic.signal").unwrap();
    wrong_agent.payload.marker = "changed".to_owned();
    assert_eq!(
        rejected(core.submit_command(wrong_agent).unwrap()),
        AdmissionRejection::AgentInstanceConflict
    );
    let mut invalid_compiled = original.clone();
    invalid_compiled.kind = CommandKind::new("synthetic.signal").unwrap();
    assert_eq!(
        core.submit_command(invalid_compiled),
        Err(CoreFatalError::InvalidCompiledCommand)
    );
    clock.set(120);
    core.devices.remove(&device_id("lane-a.device"));
    let mut retry = original.clone();
    retry.request_id = RequestId::new("request-b").unwrap();
    assert!(matches!(
        core.submit_command(retry).unwrap(),
        AdmissionDecision::Deduplicated(CommandState::Accepted(_))
    ));
    let mut changed = original;
    changed.payload.marker = "changed".to_owned();
    assert_eq!(
        rejected(core.submit_command(changed).unwrap()),
        AdmissionRejection::SemanticConflict
    );
    assert_eq!(core.queue.reserve_calls, 1);
    assert_eq!(core.retained_command_count(), 1);
}

#[test]
fn every_retained_semantic_dimension_conflicts_before_freshness() {
    let clock = FakeClock::new(100);
    let mut core = core(clock.clone(), limits(), FakeQueue::default());
    let original = command("same", "request-a", 105, 10);
    accepted(core.submit_command(original.clone()).unwrap());
    clock.set(120);
    let mut variants = Vec::new();
    let mut changed = original.clone();
    changed.device_id = device_id("other");
    variants.push(changed);
    let mut changed = original.clone();
    changed.expected_binding_instance_id = binding("other");
    variants.push(changed);
    let mut changed = original.clone();
    changed.not_after_agent_uptime_ms = AgentUptimeMs::new(104);
    variants.push(changed);
    let mut changed = original.clone();
    changed.kind = CommandKind::new("synthetic.signal").unwrap();
    changed.payload.variant = SyntheticKind::Signal;
    variants.push(changed);
    let mut changed = original.clone();
    changed.timeout_ms = CommandTimeoutMs::new(11).unwrap();
    variants.push(changed);
    let mut changed = original;
    changed.payload.marker = "other".to_owned();
    variants.push(changed);
    for variant in variants {
        assert_eq!(
            rejected(core.submit_command(variant).unwrap()),
            AdmissionRejection::SemanticConflict
        );
    }
    assert_eq!(core.queue.reserve_calls, 1);
}

#[test]
fn freshness_horizon_timeout_and_clock_boundaries_are_exact() {
    let clock = FakeClock::new(100);
    let mut roomy_limits = limits();
    roomy_limits.max_command_records = 6;
    let mut core = core(clock.clone(), roomy_limits, FakeQueue::default());
    assert_eq!(
        rejected(
            core.submit_command(command("expired", "r", 99, 10))
                .unwrap()
        ),
        AdmissionRejection::SubmissionExpired
    );
    accepted(core.submit_command(command("equal", "r", 100, 10)).unwrap());
    accepted(
        core.submit_command(command("horizon", "r", 110, 10))
            .unwrap(),
    );
    assert_eq!(
        rejected(
            core.submit_command(command("too-far", "r", 111, 10))
                .unwrap()
        ),
        AdmissionRejection::SubmissionHorizonExceeded
    );
    assert_eq!(
        rejected(
            core.submit_command(command("too-long", "r", 100, 11))
                .unwrap()
        ),
        AdmissionRejection::TimeoutTooLarge
    );
    assert_eq!(core.queue.reserve_calls, 2);

    let near_max = FakeClock::new(u64::MAX - 2);
    let mut near_max_core = TestCore::new(
        agent(),
        vec![normal_seed()],
        limits(),
        near_max.clone(),
        FakeQueue::default(),
    )
    .unwrap();
    accepted(
        near_max_core
            .submit_command(command("max", "r", u64::MAX, 10))
            .unwrap(),
    );
    assert_eq!(near_max_core.queue.reserve_calls, 1);
    near_max.set(u64::MAX - 3);
    assert_eq!(
        near_max_core.submit_command(command("regressed", "r", 100, 10)),
        Err(CoreFatalError::ClockRegression)
    );
}

#[test]
fn device_binding_and_capability_checks_do_not_impose_a_ready_gate() {
    let clock = FakeClock::new(100);
    let mut core = core(clock.clone(), limits(), FakeQueue::default());
    let mut unknown = command("unknown", "r", 100, 10);
    unknown.device_id = device_id("missing");
    assert_eq!(
        rejected(core.submit_command(unknown).unwrap()),
        AdmissionRejection::UnknownDevice
    );
    let mut wrong_binding = command("wrong", "r", 100, 10);
    wrong_binding.expected_binding_instance_id = binding("old");
    assert_eq!(
        rejected(core.submit_command(wrong_binding).unwrap()),
        AdmissionRejection::BindingInstanceConflict
    );
    core.devices
        .get_mut(&device_id("lane-a.device"))
        .unwrap()
        .snapshot
        .binding_instance_id = None;
    assert_eq!(
        rejected(
            core.submit_command(command("unbound", "r", 100, 10))
                .unwrap()
        ),
        AdmissionRejection::BindingInstanceConflict
    );
    let mut degraded = normal_seed();
    degraded.snapshot.availability = DeviceAvailability::Degraded;
    degraded
        .snapshot
        .capabilities
        .remove(&capability("synthetic.signal"));
    degraded
        .capability_resources
        .retain(|(cap, _)| cap != &capability("synthetic.signal"));
    let mut core = TestCore::new(
        agent(),
        vec![degraded],
        limits(),
        clock,
        FakeQueue::default(),
    )
    .unwrap();
    let mut signal = command("signal", "r", 100, 10);
    signal.kind = CommandKind::new("synthetic.signal").unwrap();
    signal.payload.variant = SyntheticKind::Signal;
    assert_eq!(
        rejected(core.submit_command(signal).unwrap()),
        AdmissionRejection::CapabilityUnavailable
    );
    accepted(
        core.submit_command(command("observe", "r", 100, 10))
            .unwrap(),
    );
}

#[test]
fn protected_cache_capacity_is_checked_before_queue_reservation() {
    let clock = FakeClock::new(100);
    let mut tiny = limits();
    tiny.max_command_records = 1;
    let mut core = core(clock.clone(), tiny, FakeQueue::default());
    accepted(
        core.submit_command(command("active", "r", 100, 10))
            .unwrap(),
    );
    clock.set(120);
    assert_eq!(
        rejected(core.submit_command(command("next", "r", 120, 10)).unwrap()),
        AdmissionRejection::CommandCacheFull
    );
    assert_eq!(core.queue.reserve_calls, 1);
    assert_eq!(core.retained_command_count(), 1);
    assert!(
        core.command_status(&CommandId::new("active").unwrap())
            .is_some()
    );
}

#[test]
fn queue_reservation_failure_never_creates_a_record() {
    for (failure, expected) in [
        (
            QueueReservationError::Full,
            AdmissionRejection::ExecutorQueueFull,
        ),
        (
            QueueReservationError::Unavailable,
            AdmissionRejection::ExecutorUnavailable,
        ),
    ] {
        let queue = FakeQueue {
            fail_reserve: Some(failure),
            ..FakeQueue::default()
        };
        let mut core = core(FakeClock::new(100), limits(), queue);
        assert_eq!(
            rejected(core.submit_command(command("one", "r", 100, 10)).unwrap()),
            expected
        );
        assert_eq!(core.queue.reserve_calls, 1);
        assert_eq!(core.queue.commit_calls, 0);
        assert_eq!(core.retained_command_count(), 0);
        assert!(
            core.command_status(&CommandId::new("one").unwrap())
                .is_none()
        );
    }
}

#[test]
fn queue_commit_observes_record_then_failure_keeps_non_effect_identity() {
    let queue = FakeQueue {
        fail_commit: true,
        ..FakeQueue::default()
    };
    let mut core = core(FakeClock::new(100), limits(), queue);
    let original = command("one", "r-a", 105, 10);
    let state = accepted(core.submit_command(original.clone()).unwrap());
    let CommandState::Terminal(terminal) = state else {
        panic!("guaranteed non-enqueue must terminalize");
    };
    assert_eq!(terminal.outcome, TerminalOutcome::Failed);
    assert_eq!(terminal.effect_evidence, EffectEvidence::None);
    assert_eq!(terminal.terminal_agent_uptime_ms, AgentUptimeMs::new(100));
    assert_eq!(core.queue.reserve_calls, 1);
    assert_eq!(core.queue.commit_calls, 1);
    assert!(core.queue.witness_seen);
    assert!(core.queue.committed.is_empty());
    assert_eq!(core.retained_command_count(), 1);
    let mut retry = original;
    retry.request_id = RequestId::new("r-b").unwrap();
    assert!(matches!(
        core.submit_command(retry).unwrap(),
        AdmissionDecision::Deduplicated(CommandState::Terminal(_))
    ));
    assert_eq!(core.queue.reserve_calls, 1);
}

#[test]
fn successful_queue_commit_has_a_record_before_visibility() {
    let mut core = core(FakeClock::new(100), limits(), FakeQueue::default());
    accepted(core.submit_command(command("one", "r", 100, 10)).unwrap());
    assert!(core.queue.witness_seen);
    assert_eq!(core.queue.commit_calls, 1);
    assert_eq!(core.queue.committed, vec![CommandId::new("one").unwrap()]);
    assert_eq!(core.queue.reserved_resources, vec![ResourceId::new(7)]);
    let CommandRecord::Active { state, .. } =
        core.records.get(&CommandId::new("one").unwrap()).unwrap()
    else {
        panic!("expected retained active record");
    };
    // The borrow observed during commit aliases the retained map entry, not a
    // local state prepared before record creation. No raw pointer is dereferenced.
    assert_eq!(
        core.queue.recorded_address_at_commit,
        Some(std::ptr::from_ref(state) as usize)
    );
    assert!(matches!(
        core.command_status(&CommandId::new("one").unwrap()),
        Some(CommandState::Accepted(_))
    ));
}

#[test]
fn terminal_compaction_drops_payload_but_preserves_dedupe_and_conflict() {
    let clock = FakeClock::new(100);
    let mut core = core(clock.clone(), limits(), FakeQueue::default());
    let mut original = command("one", "r-a", 105, 10);
    original.payload.marker = "SYNTHETIC_PRIVATE_MARKER".to_owned();
    accepted(core.submit_command(original.clone()).unwrap());
    let weak: Weak<SyntheticCommand> = match core.records.get(&original.command_id).unwrap() {
        CommandRecord::Active { _payload, .. } => Arc::downgrade(_payload),
        CommandRecord::Terminal { .. } => panic!("expected active record"),
    };
    assert!(weak.upgrade().is_some());
    terminate_without_effect(&mut core, &clock, "one", 101);
    assert!(weak.upgrade().is_none());
    core.devices.remove(&device_id("lane-a.device"));
    let retained = core.records.get(&original.command_id).unwrap();
    assert!(matches!(retained, CommandRecord::Terminal { .. }));
    let status = core.command_status(&original.command_id).unwrap();
    for diagnostic in [format!("{core:?}"), format!("{status:?}")] {
        assert!(!diagnostic.contains("SYNTHETIC_PRIVATE_MARKER"));
    }
    assert!(
        !core
            .queue
            .queued_debug
            .as_ref()
            .unwrap()
            .contains("SYNTHETIC_PRIVATE_MARKER")
    );
    let mut retry = original.clone();
    retry.request_id = RequestId::new("r-b").unwrap();
    assert!(matches!(
        core.submit_command(retry).unwrap(),
        AdmissionDecision::Deduplicated(CommandState::Terminal(_))
    ));
    let mut changed = original;
    changed.payload.marker = "different".to_owned();
    assert_eq!(
        rejected(core.submit_command(changed).unwrap()),
        AdmissionRejection::SemanticConflict
    );
}

#[test]
fn terminal_identity_survives_deadline_equality_then_eviction_fences_replay() {
    let clock = FakeClock::new(100);
    let mut tiny = limits();
    tiny.max_command_records = 1;
    let mut core = core(clock.clone(), tiny, FakeQueue::default());
    let original = command("old", "r-a", 105, 10);
    accepted(core.submit_command(original.clone()).unwrap());
    terminate_without_effect(&mut core, &clock, "old", 100);
    clock.set(105); // Recovery elapsed, but U == D still protects identity.
    assert_eq!(
        rejected(core.submit_command(command("new", "r", 105, 10)).unwrap()),
        AdmissionRejection::CommandCacheFull
    );
    assert_eq!(core.queue.reserve_calls, 1);
    let mut retry = original.clone();
    retry.request_id = RequestId::new("r-b").unwrap();
    assert!(matches!(
        core.submit_command(retry).unwrap(),
        AdmissionDecision::Deduplicated(CommandState::Terminal(_))
    ));
    clock.set(106);
    accepted(core.submit_command(command("new", "r", 106, 10)).unwrap());
    assert_eq!(core.retained_command_count(), 1);
    assert!(core.command_status(&original.command_id).is_none());
    assert_eq!(
        rejected(core.submit_command(original).unwrap()),
        AdmissionRejection::SubmissionExpired
    );
}

#[test]
fn terminal_recovery_age_is_required_and_exact_boundary_is_evictable() {
    let clock = FakeClock::new(100);
    let mut tiny = limits();
    tiny.max_command_records = 1;
    let mut core = core(clock.clone(), tiny, FakeQueue::default());
    accepted(core.submit_command(command("old", "r", 101, 10)).unwrap());
    terminate_without_effect(&mut core, &clock, "old", 102);
    clock.set(106); // U > D, but recovery age is only 4 of 5 ms.
    assert_eq!(
        rejected(core.submit_command(command("new", "r", 106, 10)).unwrap()),
        AdmissionRejection::CommandCacheFull
    );
    clock.set(107); // U - T == R.
    accepted(core.submit_command(command("new", "r", 107, 10)).unwrap());
    assert!(
        core.command_status(&CommandId::new("old").unwrap())
            .is_none()
    );
    assert_eq!(core.retained_command_count(), 1);
    assert_eq!(core.queue.reserve_calls, 2);
}

#[test]
fn reclaim_uses_admission_order_not_opaque_command_id_order() {
    let clock = FakeClock::new(100);
    let mut tiny = limits();
    tiny.max_command_records = 2;
    let mut core = core(clock.clone(), tiny, FakeQueue::default());
    accepted(
        core.submit_command(command("z-first", "r", 100, 10))
            .unwrap(),
    );
    accepted(
        core.submit_command(command("a-second", "r", 100, 10))
            .unwrap(),
    );
    terminate_without_effect(&mut core, &clock, "z-first", 100);
    terminate_without_effect(&mut core, &clock, "a-second", 100);
    clock.set(105);
    accepted(core.submit_command(command("third", "r", 105, 10)).unwrap());
    assert!(
        core.command_status(&CommandId::new("z-first").unwrap())
            .is_none()
    );
    assert!(
        core.command_status(&CommandId::new("a-second").unwrap())
            .is_some()
    );
    assert_eq!(core.retained_command_count(), 2);
}

#[test]
fn evictable_retained_retry_is_resolved_before_reclamation() {
    let clock = FakeClock::new(100);
    let mut tiny = limits();
    tiny.max_command_records = 1;
    let mut core = core(clock.clone(), tiny, FakeQueue::default());
    let original = command("old", "r-a", 100, 10);
    accepted(core.submit_command(original.clone()).unwrap());
    terminate_without_effect(&mut core, &clock, "old", 100);
    clock.set(105); // Both retention conditions permit eviction.
    let mut retry = original.clone();
    retry.request_id = RequestId::new("r-b").unwrap();
    assert!(matches!(
        core.submit_command(retry).unwrap(),
        AdmissionDecision::Deduplicated(CommandState::Terminal(_))
    ));
    let mut conflict = original.clone();
    conflict.payload.marker = "changed".to_owned();
    assert_eq!(
        rejected(core.submit_command(conflict).unwrap()),
        AdmissionRejection::SemanticConflict
    );
    assert!(core.command_status(&original.command_id).is_some());
    assert_eq!(core.retained_command_count(), 1);
    assert_eq!(core.queue.reserve_calls, 1);
}

#[test]
fn clock_regression_is_fatal_even_for_a_retained_retry() {
    let clock = FakeClock::new(100);
    let mut core = core(clock.clone(), limits(), FakeQueue::default());
    let original = command("one", "r-a", 100, 10);
    accepted(core.submit_command(original.clone()).unwrap());
    clock.set(99);
    assert_eq!(
        core.submit_command(original),
        Err(CoreFatalError::ClockRegression)
    );
    assert_eq!(core.queue.reserve_calls, 1);
    assert_eq!(core.retained_command_count(), 1);
}

#[test]
fn sequence_overflow_releases_the_uncommitted_reservation() {
    let mut core = core(FakeClock::new(100), limits(), FakeQueue::default());
    core.next_admission_sequence = u64::MAX;
    assert_eq!(
        core.submit_command(command("one", "r", 100, 10)),
        Err(CoreFatalError::RecordSequenceOverflow)
    );
    assert_eq!(core.queue.reserve_calls, 1);
    assert_eq!(core.queue.commit_calls, 0);
    assert_eq!(core.queue.outstanding_reservations.get(), 0);
    assert_eq!(core.retained_command_count(), 0);
}

#[test]
fn bound_published_capability_requires_a_resource_mapping() {
    let mut incomplete = normal_seed();
    incomplete.capability_resources.pop();
    let result = TestCore::new(
        agent(),
        vec![incomplete],
        limits(),
        FakeClock::new(100),
        FakeQueue::default(),
    );
    assert_eq!(result.unwrap_err(), CoreFatalError::MissingResourceMapping);
}
