use super::*;

fn next(core: &mut Core, token: &SubscriptionToken) -> EdgeEvent {
    match core.poll_event(token).unwrap() {
        EventPoll::Event(event) => event,
        other => panic!("expected event, got {other:?}"),
    }
}

fn sequence(event: &EdgeEvent) -> u64 {
    match event {
        EdgeEvent::DeviceStateChanged(v) => v.sequence.get(),
        EdgeEvent::CommandStateChanged(v) => v.sequence.get(),
        _ => panic!("not sequenced"),
    }
}

pub(super) fn fresh_adapters(
    weak: &Rc<RefCell<Vec<Weak<Payload>>>>,
) -> (Vec<(ResourceId, ObservedAdapter)>, Vec<SimProbe>) {
    let mut probes = Vec::new();
    let adapters = [7, 9]
        .map(|resource| {
            let (inner, probe) = ScriptedAdapter::new([Script::new([
                Step::MarkPossible,
                Step::MarkConfirmed,
                Step::CompleteSuccess,
            ])
            .unwrap()])
            .unwrap();
            probes.push(probe);
            (
                ResourceId::new(resource),
                ObservedAdapter {
                    inner,
                    weak: weak.clone(),
                },
            )
        })
        .into();
    (adapters, probes)
}

#[test]
fn installation_cannot_use_another_cores_queue() {
    let mut f = fixture(2, [vec![], vec![]]);
    f.core
        .invalidate_binding(&device(), &binding(), BindingInvalidation::Disconnected)
        .unwrap();
    f.core.begin_connecting(&device()).unwrap();
    let (_producer, consumer) =
        bounded_executor_queue([ResourceId::new(7), ResourceId::new(9)], 2, 2).unwrap();
    let mut foreign = ExecutorSupervisor::new(consumer).unwrap();
    let (adapters, _) = fresh_adapters(&f.weak);
    let result = foreign.install_binding(
        &mut f.core,
        &device(),
        &BindingInstanceId::new("b").unwrap(),
        adapters,
    );
    assert!(matches!(
        result,
        Err(LifecycleError::Fatal(
            CoreFatalError::BindingInstallationInvariant
        ))
    ));
    assert!(
        f.core
            .device_snapshot(&device())
            .unwrap()
            .binding_instance_id
            .is_none()
    );
}

#[test]
fn current_invalidation_and_rebind_keep_one_truth_and_ignore_old_facts() {
    let mut f = fixture(2, [vec![], vec![]]);
    let initial = f.core.device_snapshot(&device()).unwrap().clone();
    assert_eq!(initial.state_revision.get(), 2);
    assert_eq!(initial.binding_instance_id, Some(binding()));
    let sub = f.core.open_event_subscription().unwrap();
    assert_eq!(
        f.core
            .invalidate_binding(&device(), &binding(), BindingInvalidation::Disconnected)
            .unwrap(),
        LifecycleChange::Changed
    );
    let absent = f.core.device_snapshot(&device()).unwrap();
    assert_eq!(absent.binding_instance_id, None);
    assert!(absent.capabilities.is_empty());
    assert_eq!(absent.availability, DeviceAvailability::Absent);
    assert_eq!(absent.state_revision.get(), 3);
    f.core.begin_connecting(&device()).unwrap();
    assert_eq!(
        f.core.begin_connecting(&device()).unwrap(),
        LifecycleChange::Unchanged
    );
    assert_eq!(
        f.core
            .device_snapshot(&device())
            .unwrap()
            .state_revision
            .get(),
        4
    );
    let b = BindingInstanceId::new("binding-b-same-simulated-hardware").unwrap();
    let (adapters, _) = fresh_adapters(&f.weak);
    let witness = f
        .executor
        .install_binding(&mut f.core, &device(), &b, adapters)
        .unwrap();
    // Installation is not activation.
    assert_eq!(
        f.core
            .device_snapshot(&device())
            .unwrap()
            .binding_instance_id,
        None
    );
    f.core.activate_binding(witness, bound_state()).unwrap();
    let replacement = f.core.device_snapshot(&device()).unwrap().clone();
    assert_eq!(replacement.binding_instance_id, Some(b.clone()));
    assert_eq!(replacement.state_revision.get(), 5);
    let cursor = f.core.event_cursor();
    assert_eq!(
        f.core
            .invalidate_binding(&device(), &binding(), BindingInvalidation::ExecutionFault)
            .unwrap(),
        LifecycleChange::Stale
    );
    assert_eq!(
        f.core
            .update_bound_device_state(&device(), &binding(), bound_state())
            .unwrap(),
        LifecycleChange::Stale
    );
    assert_eq!(
        f.core
            .update_bound_device_state(&device(), &b, bound_state())
            .unwrap(),
        LifecycleChange::Unchanged
    );
    assert_eq!(f.core.event_cursor(), cursor);
    assert_eq!(f.core.device_snapshot(&device()), Some(&replacement));
    for expected in [3, 4, 5] {
        let EdgeEvent::DeviceStateChanged(event) = next(&mut f.core, &sub.token) else {
            panic!("expected device event");
        };
        assert_eq!(event.sequence.get(), expected);
        assert_eq!(event.agent_instance_id, event.device.agent_instance_id);
        assert_eq!(event.device_id, event.device.device_id);
        assert_eq!(event.binding_instance_id, event.device.binding_instance_id);
        assert_eq!(event.state_revision, event.device.state_revision);
    }
    assert_eq!(f.core.poll_event(&sub.token).unwrap(), EventPoll::Empty);
}

#[test]
fn binding_history_is_bounded_and_used_ids_cannot_return() {
    let mut limits = CoreLimits::with_registry_bounds(1, 2, 2, 1);
    limits.max_binding_epochs_per_agent = 2;
    let mut f = fixture_with_limits(2, [vec![], vec![]], limits);
    f.core
        .invalidate_binding(&device(), &binding(), BindingInvalidation::ExecutionFault)
        .unwrap();
    f.core.begin_connecting(&device()).unwrap();
    let (adapters, _) = fresh_adapters(&f.weak);
    assert!(matches!(
        f.executor
            .install_binding(&mut f.core, &device(), &binding(), adapters),
        Err(LifecycleError::Rejected(LifecycleRejection::BindingIdUsed))
    ));
    let b = BindingInstanceId::new("b").unwrap();
    let (adapters, _) = fresh_adapters(&f.weak);
    let witness = f
        .executor
        .install_binding(&mut f.core, &device(), &b, adapters)
        .unwrap();
    f.core.activate_binding(witness, bound_state()).unwrap();
    f.core
        .invalidate_binding(&device(), &b, BindingInvalidation::Disconnected)
        .unwrap();
    f.core.begin_connecting(&device()).unwrap();
    let (adapters, _) = fresh_adapters(&f.weak);
    assert!(matches!(
        f.executor.install_binding(
            &mut f.core,
            &device(),
            &BindingInstanceId::new("c").unwrap(),
            adapters
        ),
        Err(LifecycleError::Rejected(
            LifecycleRejection::BindingHistoryFull
        ))
    ));
    assert_eq!(
        f.core.device_snapshot(&device()).unwrap().availability,
        DeviceAvailability::Connecting
    );
    assert!(
        f.core
            .device_snapshot(&device())
            .unwrap()
            .binding_instance_id
            .is_none()
    );
}

#[test]
fn incomplete_and_replaced_installations_cannot_activate() {
    let mut f = fixture(2, [vec![], vec![]]);
    f.core
        .invalidate_binding(&device(), &binding(), BindingInvalidation::Disconnected)
        .unwrap();
    f.core.begin_connecting(&device()).unwrap();
    let b = BindingInstanceId::new("b").unwrap();
    let (mut adapters, _) = fresh_adapters(&f.weak);
    adapters.pop();
    assert!(matches!(
        f.executor
            .install_binding(&mut f.core, &device(), &b, adapters),
        Err(LifecycleError::Rejected(
            LifecycleRejection::IncompleteInstallation
        ))
    ));
    assert!(
        f.core
            .device_snapshot(&device())
            .unwrap()
            .binding_instance_id
            .is_none()
    );
    let (adapters, _) = fresh_adapters(&f.weak);
    let old = f
        .executor
        .install_binding(&mut f.core, &device(), &b, adapters)
        .unwrap();
    let (adapters, _) = fresh_adapters(&f.weak);
    let fresh = f
        .executor
        .install_binding(
            &mut f.core,
            &device(),
            &BindingInstanceId::new("c").unwrap(),
            adapters,
        )
        .unwrap();
    assert_eq!(
        f.core.activate_binding(old, bound_state()),
        Err(LifecycleError::Rejected(
            LifecycleRejection::StaleInstallation
        ))
    );
    f.core.activate_binding(fresh, bound_state()).unwrap();
}

#[test]
fn active_and_queued_old_commands_never_use_replacement_adapters() {
    let mut f = fixture(
        3,
        [
            vec![vec![Step::MarkPossible, Step::StallForever]],
            vec![vec![Step::MarkPossible, Step::StallForever]],
        ],
    );
    f.submit("active", 7, 100);
    f.submit("queued", 7, 100);
    f.submit("sibling", 9, 100);
    f.drive();
    f.drive();
    f.core
        .invalidate_binding(&device(), &binding(), BindingInvalidation::Disconnected)
        .unwrap();
    f.core.begin_connecting(&device()).unwrap();
    let b = BindingInstanceId::new("b").unwrap();
    let (adapters, probes) = fresh_adapters(&f.weak);
    let witness = f
        .executor
        .install_binding(&mut f.core, &device(), &b, adapters)
        .unwrap();
    f.terminal("active", TerminalOutcome::Unknown, EffectEvidence::Possible);
    f.terminal(
        "sibling",
        TerminalOutcome::Unknown,
        EffectEvidence::Possible,
    );
    assert!(f.weak.borrow().iter().all(|v| v.upgrade().is_none()));
    f.core.activate_binding(witness, bound_state()).unwrap();
    f.drive();
    let old = f.terminal("queued", TerminalOutcome::Failed, EffectEvidence::None);
    assert_eq!(old.binding_instance_id, binding());
    assert!(probes.iter().all(|p| p.metrics().begins == 0));
    let cursor = f.core.event_cursor();
    assert!(matches!(
        f.core.submit_command(command("active", 7, 100)).unwrap(),
        AdmissionDecision::Deduplicated(_)
    ));
    assert_eq!(f.core.event_cursor(), cursor);
    let mut conflict = command("active", 7, 100);
    conflict.expected_binding_instance_id = b.clone();
    assert_eq!(
        f.core.submit_command(conflict).unwrap(),
        AdmissionDecision::Rejected(AdmissionRejection::SemanticConflict)
    );
    let mut new = command("fresh", 7, 100);
    new.expected_binding_instance_id = b;
    f.core.submit_command(new).unwrap();
    for _ in 0..4 {
        f.drive();
    }
    f.terminal(
        "fresh",
        TerminalOutcome::Succeeded,
        EffectEvidence::Confirmed,
    );
    assert_eq!(probes[0].metrics().begins, 1);
    assert_eq!(f.probes[0].metrics().begins, 1);
}

#[test]
fn snapshot_registration_and_interleaved_state_events_share_one_sequence() {
    let mut f = fixture(
        2,
        [
            vec![vec![
                Step::MarkPossible,
                Step::MarkConfirmed,
                Step::CompleteSuccess,
            ]],
            vec![],
        ],
    );
    let sub = f.core.open_event_subscription().unwrap();
    let n = sub.snapshot.event_cursor.get();
    assert_eq!(n, 2); // Connecting and binding activation advanced without a subscriber.
    assert_eq!(sub.snapshot.devices.len(), 1);
    assert_eq!(
        sub.snapshot.devices[0],
        *f.core.device_snapshot(&device()).unwrap()
    );
    let mut ready = bound_state();
    ready.availability = BoundAvailability::Ready;
    f.core
        .update_bound_device_state(&device(), &binding(), ready)
        .unwrap();
    f.submit("a", 7, 100);
    f.core.emit_heartbeat().unwrap();
    assert_eq!(f.core.event_cursor().get(), n + 2);
    f.drive();
    f.core
        .update_bound_device_state(&device(), &binding(), bound_state())
        .unwrap();
    f.drive();
    f.drive();
    f.drive();
    // Accepted/Executing/Terminal events are still queued here; their public
    // DTOs must not keep the full command payload alive after completion.
    assert!(f.weak.borrow().iter().all(|v| v.upgrade().is_none()));
    let mut phases = Vec::new();
    let mut numbers = Vec::new();
    loop {
        match f.core.poll_event(&sub.token).unwrap() {
            EventPoll::Event(event) => {
                if let EdgeEvent::Heartbeat(beat) = &event {
                    assert_eq!(beat.agent_uptime_ms.get(), 100);
                    continue;
                }
                numbers.push(sequence(&event));
                if let EdgeEvent::CommandStateChanged(command) = event {
                    phases.push(command.command);
                }
            }
            EventPoll::Empty => break,
            _ => panic!("unexpected close"),
        }
    }
    assert_eq!(numbers, [n + 1, n + 2, n + 3, n + 4, n + 5]);
    assert!(matches!(
        &phases[..],
        [
            CommandState::Accepted(_),
            CommandState::Executing(_),
            CommandState::Terminal(_)
        ]
    ));
    let cursor = f.core.event_cursor();
    f.core.submit_command(command("a", 7, 100)).unwrap();
    assert_eq!(f.core.event_cursor(), cursor);
    assert_eq!(f.core.poll_event(&sub.token).unwrap(), EventPoll::Empty);
    let text = format!("{phases:?}{:?}", sub.snapshot);
    assert!(!text.contains("PRIVATE_SENTINEL"));
}

#[test]
fn execution_fault_publishes_device_invalidation_before_original_binding_terminal() {
    let mut f = fixture(
        2,
        [
            vec![vec![Step::MarkPossible, Step::MarkConfirmed, Step::Panic]],
            vec![],
        ],
    );
    let sub = f.core.open_event_subscription().unwrap();
    f.submit("a", 7, 100);
    for _ in 0..4 {
        f.drive();
    }
    assert!(matches!(
        next(&mut f.core, &sub.token),
        EdgeEvent::CommandStateChanged(_)
    ));
    assert!(matches!(
        next(&mut f.core, &sub.token),
        EdgeEvent::CommandStateChanged(_)
    ));
    let EdgeEvent::DeviceStateChanged(device_event) = next(&mut f.core, &sub.token) else {
        panic!("expected invalidation");
    };
    assert_eq!(
        device_event.device.availability,
        DeviceAvailability::Faulted
    );
    assert_eq!(device_event.device.binding_instance_id, None);
    assert!(device_event.device.capabilities.is_empty());
    let EdgeEvent::CommandStateChanged(command_event) = next(&mut f.core, &sub.token) else {
        panic!("expected terminal");
    };
    assert_eq!(
        command_event.sequence.get(),
        device_event.sequence.get() + 1
    );
    let CommandState::Terminal(terminal) = command_event.command else {
        panic!("expected terminal");
    };
    assert_eq!(terminal.binding_instance_id, binding());
    assert_eq!(
        (terminal.outcome, terminal.effect_evidence),
        (TerminalOutcome::Succeeded, EffectEvidence::Confirmed)
    );
}

#[test]
fn queue_overflow_commits_state_closes_continuity_and_reopens_without_replay() {
    let mut limits = CoreLimits::with_registry_bounds(1, 2, 2, 1);
    limits.max_event_queue_records = 2;
    let mut f = fixture_with_limits(2, [vec![], vec![]], limits);
    let a = f.core.open_event_subscription().unwrap();
    assert_eq!(
        f.core.open_event_subscription().unwrap_err(),
        SubscriptionError::AlreadyActive
    );
    for availability in [
        BoundAvailability::Ready,
        BoundAvailability::Degraded,
        BoundAvailability::Ready,
    ] {
        let mut state = bound_state();
        state.availability = availability;
        f.core
            .update_bound_device_state(&device(), &binding(), state)
            .unwrap();
    }
    assert_eq!(
        f.core.event_cursor().get(),
        a.snapshot.event_cursor.get() + 3
    );
    assert_eq!(
        f.core
            .device_snapshot(&device())
            .unwrap()
            .state_revision
            .get(),
        5
    );
    assert_eq!(f.core.poll_event(&a.token).unwrap(), EventPoll::Closed);
    let b = f.core.open_event_subscription().unwrap();
    assert_eq!(b.snapshot.event_cursor, f.core.event_cursor());
    assert_eq!(b.snapshot.devices[0].state_revision.get(), 5);
    assert_eq!(f.core.poll_event(&a.token).unwrap(), EventPoll::StaleToken);
    assert!(!f.core.close_event_subscription(&a.token).unwrap());
    assert_eq!(f.core.poll_event(&b.token).unwrap(), EventPoll::Empty);
    f.core
        .invalidate_binding(&device(), &binding(), BindingInvalidation::Disconnected)
        .unwrap();
    assert_eq!(
        sequence(&next(&mut f.core, &b.token)),
        b.snapshot.event_cursor.get() + 1
    );
    assert!(f.core.close_event_subscription(&b.token).unwrap());
    assert_eq!(f.core.poll_event(&b.token).unwrap(), EventPoll::Closed);
    let c = f.core.open_event_subscription().unwrap();
    assert_eq!(f.core.poll_event(&c.token).unwrap(), EventPoll::Empty);
}

#[test]
fn heartbeat_overflow_closes_subscription_without_advancing_cursor() {
    let mut limits = CoreLimits::with_registry_bounds(1, 2, 2, 1);
    limits.max_event_queue_records = 2;
    let mut f = fixture_with_limits(2, [vec![], vec![]], limits);
    let sub = f.core.open_event_subscription().unwrap();
    f.core.emit_heartbeat().unwrap();
    f.core.emit_heartbeat().unwrap();
    assert_eq!(
        f.core.poll_event(&sub.token).unwrap(),
        EventPoll::Event(EdgeEvent::Heartbeat(HeartbeatEvent {
            agent_instance_id: AgentInstanceId::new("agent-a").unwrap(),
            agent_uptime_ms: AgentUptimeMs::new(100)
        }))
    );
    f.core.emit_heartbeat().unwrap();
    f.core.emit_heartbeat().unwrap();
    assert_eq!(f.core.poll_event(&sub.token).unwrap(), EventPoll::Closed);
    assert_eq!(f.core.event_cursor(), sub.snapshot.event_cursor);
    assert_eq!(
        f.core
            .open_event_subscription()
            .unwrap()
            .snapshot
            .event_cursor,
        sub.snapshot.event_cursor
    );
}

#[test]
fn oversized_required_event_fails_before_public_state_mutation_and_stops_core() {
    let mut limits = CoreLimits::with_registry_bounds(1, 2, 2, 1);
    let mut candidate = seed().snapshot;
    candidate.binding_instance_id = Some(binding());
    candidate.state_revision = StateRevision::new(3);
    candidate.availability = DeviceAvailability::Ready;
    candidate.capabilities = bound_state().capabilities;
    candidate
        .conditions
        .insert(ConditionCode::new(format!("edge.{}", "x".repeat(250))).unwrap());
    let event = EdgeEvent::DeviceStateChanged(Box::new(DeviceStateChangedEvent {
        agent_instance_id: candidate.agent_instance_id.clone(),
        sequence: EventSequence::new(3),
        device_id: candidate.device_id.clone(),
        binding_instance_id: candidate.binding_instance_id.clone(),
        state_revision: candidate.state_revision,
        device: candidate.clone(),
    }));
    limits.max_event_record_bytes = encode_json_bounded(&event, usize::MAX).unwrap().len() - 1;
    let mut f = fixture_with_limits(2, [vec![], vec![]], limits);
    let sub = f.core.open_event_subscription().unwrap();
    let before = f.core.device_snapshot(&device()).unwrap().clone();
    assert_eq!(
        f.core.update_bound_device_state(
            &device(),
            &binding(),
            BoundDeviceState {
                availability: BoundAvailability::Ready,
                conditions: candidate.conditions,
                capabilities: candidate.capabilities
            }
        ),
        Err(LifecycleError::Fatal(CoreFatalError::EventNotRepresentable))
    );
    assert_eq!(f.core.device_snapshot(&device()), Some(&before));
    assert_eq!(f.core.event_cursor(), sub.snapshot.event_cursor);
    assert_eq!(
        f.core.poll_event(&sub.token),
        Err(CoreFatalError::EventNotRepresentable)
    );
    assert_eq!(
        f.core.submit_command(command("a", 7, 100)),
        Err(CoreFatalError::EventNotRepresentable)
    );
    assert_eq!(
        f.executor.drive(&mut f.core),
        Err(CoreFatalError::EventNotRepresentable)
    );
}

#[test]
fn aggregate_snapshot_is_bounded_and_ordered_without_truncation() {
    let clock = Clock(Rc::new(Cell::new(100)));
    let mut second = seed();
    second.snapshot.device_id = DeviceId::new("a-first-slot").unwrap();
    second.capability_resources = second
        .capability_resources
        .into_iter()
        .map(|(cap, _)| (cap, ResourceId::new(11)))
        .collect();
    let (producer, consumer) = bounded_executor_queue(
        [ResourceId::new(7), ResourceId::new(9), ResourceId::new(11)],
        3,
        2,
    )
    .unwrap();
    let mut limits = CoreLimits::with_registry_bounds(2, 3, 2, 1);
    // Each device event fits, but two complete bound snapshots do not.
    limits.max_event_record_bytes = 512;
    let mut core = CoreActor::new(
        AgentInstanceId::new("agent-a").unwrap(),
        vec![seed(), second],
        limits,
        clock,
        producer,
    )
    .unwrap();
    let weak = Rc::new(RefCell::new(Vec::new()));
    let (adapters, _) = fresh_adapters(&weak);
    let mut executor = make_executor(&mut core, consumer, adapters);
    let other = DeviceId::new("a-first-slot").unwrap();
    core.begin_connecting(&other).unwrap();
    let (mut adapters, _) = fresh_adapters(&weak);
    let (_, adapter) = adapters.remove(0);
    let witness = executor
        .install_binding(
            &mut core,
            &other,
            &BindingInstanceId::new("other-binding").unwrap(),
            [(ResourceId::new(11), adapter)],
        )
        .unwrap();
    core.activate_binding(witness, bound_state()).unwrap();
    assert_eq!(
        core.open_event_subscription().unwrap_err(),
        SubscriptionError::SnapshotTooLarge
    );
    assert_eq!(
        core.open_event_subscription().unwrap_err(),
        SubscriptionError::SnapshotTooLarge
    );
    // Failure does not register a subscriber or truncate the configured set.
    assert!(
        core.device_snapshot(&other)
            .unwrap()
            .binding_instance_id
            .is_some()
    );
    assert!(
        core.device_snapshot(&device())
            .unwrap()
            .binding_instance_id
            .is_some()
    );
    core.emit_heartbeat().unwrap();

    // A separately qualified limit returns every device in DeviceId order.
    core.invalidate_binding(
        &other,
        &BindingInstanceId::new("other-binding").unwrap(),
        BindingInvalidation::Disconnected,
    )
    .unwrap();
    core.invalidate_binding(&device(), &binding(), BindingInvalidation::Disconnected)
        .unwrap();
    let sub = core.open_event_subscription().unwrap();
    assert_eq!(sub.snapshot.devices.len(), 2);
    assert_eq!(sub.snapshot.devices[0].device_id, other);
    assert_eq!(sub.snapshot.devices[1].device_id, device());
}

struct LifetimeAdapter {
    inner: ScriptedAdapter,
    _lifetime: Rc<()>,
}

impl DeviceAdapter<Payload> for LifetimeAdapter {
    type Operation = ScriptedOperation<Payload>;
    fn begin(&mut self, payload: Arc<Payload>) -> Result<Self::Operation, AdapterErrorCode> {
        self.inner.begin(payload)
    }
}

fn lifetime_adapters() -> (Vec<(ResourceId, LifetimeAdapter)>, std::rc::Weak<()>) {
    let lifetime = Rc::new(());
    let weak = Rc::downgrade(&lifetime);
    let adapters = [7, 9]
        .map(|r| {
            let (inner, _) = ScriptedAdapter::new([]).unwrap();
            (
                ResourceId::new(r),
                LifetimeAdapter {
                    inner,
                    _lifetime: lifetime.clone(),
                },
            )
        })
        .into();
    (adapters, weak)
}

#[test]
fn invalidation_discards_idle_old_adapters_but_keeps_fresh_pending_installation() {
    let (producer, consumer) =
        bounded_executor_queue([ResourceId::new(7), ResourceId::new(9)], 2, 2).unwrap();
    let mut core = CoreActor::new(
        AgentInstanceId::new("agent-a").unwrap(),
        vec![seed()],
        CoreLimits::with_registry_bounds(1, 2, 2, 1),
        Clock(Rc::new(Cell::new(100))),
        producer,
    )
    .unwrap();
    let (adapters, old) = lifetime_adapters();
    let mut executor = make_executor(&mut core, consumer, adapters);
    core.invalidate_binding(&device(), &binding(), BindingInvalidation::Disconnected)
        .unwrap();
    executor.drive(&mut core).unwrap();
    assert!(
        old.upgrade().is_none(),
        "idle invalidated transports must be discarded"
    );
    core.begin_connecting(&device()).unwrap();
    let (adapters, fresh) = lifetime_adapters();
    let b = BindingInstanceId::new("b").unwrap();
    let witness = executor
        .install_binding(&mut core, &device(), &b, adapters)
        .unwrap();
    executor.drive(&mut core).unwrap();
    assert!(
        fresh.upgrade().is_some(),
        "pending fresh installation remains usable"
    );
    core.activate_binding(witness, bound_state()).unwrap();
    executor.drive(&mut core).unwrap();
    assert!(fresh.upgrade().is_some());
}

#[test]
fn rejected_or_abandoned_activation_releases_fresh_adapters_on_drive() {
    for reject in [false, true] {
        let (producer, consumer) =
            bounded_executor_queue([ResourceId::new(7), ResourceId::new(9)], 2, 2).unwrap();
        let mut core = CoreActor::new(
            AgentInstanceId::new("agent-a").unwrap(),
            vec![seed()],
            CoreLimits::with_registry_bounds(1, 2, 2, 1),
            Clock(Rc::new(Cell::new(100))),
            producer,
        )
        .unwrap();
        let mut executor = ExecutorSupervisor::new(consumer).unwrap();
        core.begin_connecting(&device()).unwrap();
        let (adapters, lifetime) = lifetime_adapters();
        let witness = executor
            .install_binding(&mut core, &device(), &binding(), adapters)
            .unwrap();
        let snapshot = core.device_snapshot(&device()).unwrap().clone();
        let cursor = core.event_cursor();
        if reject {
            let mut state = bound_state();
            state.capabilities = [Capability::new("synthetic.not_configured").unwrap()].into();
            assert_eq!(
                core.activate_binding(witness, state),
                Err(LifecycleError::Rejected(
                    LifecycleRejection::CapabilityNotConfigured
                ))
            );
        } else {
            drop(witness);
        }
        assert_eq!(core.device_snapshot(&device()), Some(&snapshot));
        assert_eq!(core.event_cursor(), cursor);
        executor.drive(&mut core).unwrap();
        assert!(
            lifetime.upgrade().is_none(),
            "unowned pending installation must release every adapter"
        );
        // Cancellation does not consume an epoch or poison ordinary recovery.
        let (adapters, replacement) = lifetime_adapters();
        let witness = executor
            .install_binding(&mut core, &device(), &binding(), adapters)
            .unwrap();
        core.activate_binding(witness, bound_state()).unwrap();
        executor.drive(&mut core).unwrap();
        assert!(replacement.upgrade().is_some());
    }
}

#[test]
fn history_exhausted_between_install_and_activation_cancels_pending_adapters() {
    let other = DeviceId::new("other-slot").unwrap();
    let mut second = seed();
    second.snapshot.device_id = other.clone();
    for (_, resource) in &mut second.capability_resources {
        *resource = ResourceId::new(11);
    }
    let (producer, consumer) = bounded_executor_queue(
        [ResourceId::new(7), ResourceId::new(9), ResourceId::new(11)],
        3,
        2,
    )
    .unwrap();
    let mut limits = CoreLimits::with_registry_bounds(2, 3, 2, 1);
    limits.max_binding_epochs_per_agent = 1;
    let mut core = CoreActor::new(
        AgentInstanceId::new("agent-a").unwrap(),
        vec![seed(), second],
        limits,
        Clock(Rc::new(Cell::new(100))),
        producer,
    )
    .unwrap();
    let mut executor = ExecutorSupervisor::new(consumer).unwrap();
    core.begin_connecting(&device()).unwrap();
    core.begin_connecting(&other).unwrap();
    let (adapters, pending) = lifetime_adapters();
    let witness = executor
        .install_binding(&mut core, &device(), &binding(), adapters)
        .unwrap();
    let (mut adapters, healthy) = lifetime_adapters();
    let (_, adapter) = adapters.pop().unwrap();
    let other_witness = executor
        .install_binding(
            &mut core,
            &other,
            &BindingInstanceId::new("other-binding").unwrap(),
            [(ResourceId::new(11), adapter)],
        )
        .unwrap();
    drop(adapters);
    core.activate_binding(other_witness, bound_state()).unwrap();
    let snapshot = core.device_snapshot(&device()).unwrap().clone();
    let cursor = core.event_cursor();
    assert_eq!(
        core.activate_binding(witness, bound_state()),
        Err(LifecycleError::Rejected(
            LifecycleRejection::BindingHistoryFull
        ))
    );
    assert_eq!(core.device_snapshot(&device()), Some(&snapshot));
    assert_eq!(core.event_cursor(), cursor);
    executor.drive(&mut core).unwrap();
    assert!(pending.upgrade().is_none());
    assert!(healthy.upgrade().is_some());
}

#[test]
fn foreign_core_rejection_cancels_the_original_pending_installation() {
    let (producer, consumer) =
        bounded_executor_queue([ResourceId::new(7), ResourceId::new(9)], 2, 2).unwrap();
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
    let (adapters, lifetime) = lifetime_adapters();
    let witness = executor
        .install_binding(&mut core, &device(), &binding(), adapters)
        .unwrap();
    let mut foreign = fixture(2, [vec![], vec![]]);
    let snapshot = foreign.core.device_snapshot(&device()).unwrap().clone();
    assert_eq!(
        foreign.core.activate_binding(witness, bound_state()),
        Err(LifecycleError::Fatal(
            CoreFatalError::BindingInstallationInvariant
        ))
    );
    assert_eq!(foreign.core.device_snapshot(&device()), Some(&snapshot));
    executor.drive(&mut core).unwrap();
    assert!(lifetime.upgrade().is_none());
    assert!(
        core.device_snapshot(&device())
            .unwrap()
            .binding_instance_id
            .is_none()
    );
}

#[test]
fn partial_installation_rejection_drops_all_fresh_adapters() {
    for extra in [None, Some(ResourceId::new(7)), Some(ResourceId::new(99))] {
        let (producer, consumer) =
            bounded_executor_queue([ResourceId::new(7), ResourceId::new(9)], 2, 2).unwrap();
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
        let (mut adapters, lifetime) = lifetime_adapters();
        if let Some(resource) = extra {
            adapters[1].0 = resource;
        } else {
            adapters.pop();
        }
        let snapshot = core.device_snapshot(&device()).unwrap().clone();
        let cursor = core.event_cursor();
        assert!(matches!(
            executor.install_binding(&mut core, &device(), &binding(), adapters),
            Err(LifecycleError::Rejected(
                LifecycleRejection::IncompleteInstallation
            ))
        ));
        assert!(lifetime.upgrade().is_none());
        assert_eq!(core.device_snapshot(&device()), Some(&snapshot));
        assert_eq!(core.event_cursor(), cursor);
    }
}

#[test]
fn resource_less_installation_cannot_fabricate_a_bound_device() {
    let mut slot = seed();
    slot.capability_resources.clear();
    let (producer, consumer) = bounded_executor_queue([], 1, 1).unwrap();
    let mut core = CoreActor::new(
        AgentInstanceId::new("agent-a").unwrap(),
        vec![slot],
        CoreLimits::with_registry_bounds(1, 1, 2, 1),
        Clock(Rc::new(Cell::new(100))),
        producer,
    )
    .unwrap();
    core.begin_connecting(&device()).unwrap();
    let mut executor = ExecutorSupervisor::<Payload, ObservedAdapter>::new(consumer).unwrap();
    assert!(matches!(
        executor.install_binding(&mut core, &device(), &binding(), []),
        Err(LifecycleError::Rejected(
            LifecycleRejection::IncompleteInstallation
        ))
    ));
    assert!(
        core.device_snapshot(&device())
            .unwrap()
            .binding_instance_id
            .is_none()
    );
}
