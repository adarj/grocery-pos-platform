use super::*;

#[test]
fn qualification_default_waiting_capacity_and_fifo_survivors() {
    let scripts = (0..33)
        .map(|_| vec![Step::Pending, Step::CompleteFailed(FAILURE)])
        .collect();
    let mut f = fixture(DEFAULT_WAITING_CAPACITY, [scripts, vec![]]);
    f.submit("c-0", 7, 100);
    f.drive(); // active command is additional to the 32 waiting slots
    for n in 1..=32 {
        f.submit(&format!("c-{n}"), 7, 100);
    }
    assert_eq!(
        f.core.submit_command(command("overflow", 7, 100)).unwrap(),
        AdmissionDecision::Rejected(AdmissionRejection::ExecutorQueueFull)
    );
    assert!(f.core.command_status(&id("overflow")).is_none());
    assert_eq!(f.core.retained_command_count(), 33);
    for n in 0..33 {
        assert_eq!(f.probes[0].metrics().begins, n + 1);
        assert!(matches!(
            f.core.command_status(&id(&format!("c-{n}"))),
            Some(CommandState::Executing(_))
        ));
        f.drive(); // Pending only
        f.drive(); // contains old operation, then promotes next FIFO entry
        f.terminal(
            &format!("c-{n}"),
            TerminalOutcome::Failed,
            EffectEvidence::None,
        );
        assert_eq!(f.probes[0].metrics().operation_drops, n + 1);
    }
    assert_eq!(f.probes[0].metrics().begins, 33);
}

#[test]
fn qualification_default_binding_history_4096_epochs_fail_closed_at_4097() {
    let mut f = fixture(1, [vec![], vec![]]);
    let mut current = binding(); // first activation occupies history too
    for n in 1..4096 {
        f.core
            .invalidate_binding(&device(), &current, BindingInvalidation::Disconnected)
            .unwrap();
        f.executor.drive(&mut f.core).unwrap();
        f.core.begin_connecting(&device()).unwrap();
        current = BindingInstanceId::new(format!("epoch-{n}")).unwrap();
        let (adapters, _) = lifecycle_events::fresh_adapters(&f.weak);
        let witness = f
            .executor
            .install_binding(&mut f.core, &device(), &current, adapters)
            .unwrap();
        f.core.activate_binding(witness, bound_state()).unwrap();
    }
    assert_eq!(
        f.core
            .device_snapshot(&device())
            .unwrap()
            .state_revision
            .get(),
        2 + 4095 * 3
    );
    f.core
        .invalidate_binding(&device(), &current, BindingInvalidation::Disconnected)
        .unwrap();
    f.executor.drive(&mut f.core).unwrap();
    f.core.begin_connecting(&device()).unwrap();
    let (adapters, _) = lifecycle_events::fresh_adapters(&f.weak);
    assert!(matches!(
        f.executor.install_binding(
            &mut f.core,
            &device(),
            &BindingInstanceId::new("epoch-4096").unwrap(),
            adapters
        ),
        Err(LifecycleError::Rejected(
            LifecycleRejection::BindingHistoryFull
        ))
    ));
    assert!(
        f.core
            .device_snapshot(&device())
            .unwrap()
            .binding_instance_id
            .is_none()
    );
    assert!(
        f.core
            .device_snapshot(&device())
            .unwrap()
            .capabilities
            .is_empty()
    );
    assert_eq!(
        f.core
            .submit_command(command("no-orphan-effect", 7, 100))
            .unwrap(),
        AdmissionDecision::Rejected(AdmissionRejection::BindingInstanceConflict)
    );
}

#[test]
fn qualification_default_event_capacity_commits_257th_change_and_discards_backlog() {
    let mut f = fixture(1, [vec![], vec![]]);
    let sub = f.core.open_event_subscription().unwrap();
    let initial = sub.snapshot.event_cursor.get();
    for n in 0..256 {
        let mut state = bound_state();
        state.availability = if n % 2 == 0 {
            BoundAvailability::Ready
        } else {
            BoundAvailability::Degraded
        };
        f.core
            .update_bound_device_state(&device(), &binding(), state)
            .unwrap();
        assert!(f.core.event_subscription_active(&sub.token).unwrap());
    }
    let mut next = bound_state();
    next.availability = BoundAvailability::Ready;
    f.core
        .update_bound_device_state(&device(), &binding(), next)
        .unwrap();
    assert_eq!(f.core.event_cursor().get(), initial + 257);
    assert_eq!(
        f.core
            .device_snapshot(&device())
            .unwrap()
            .state_revision
            .get(),
        259
    );
    assert_eq!(f.core.poll_event(&sub.token).unwrap(), EventPoll::Closed);
    let fresh = f.core.open_event_subscription().unwrap();
    assert_eq!(fresh.snapshot.event_cursor.get(), initial + 257);
    assert_eq!(f.core.poll_event(&fresh.token).unwrap(), EventPoll::Empty);
    assert_eq!(
        f.core.poll_event(&sub.token).unwrap(),
        EventPoll::StaleToken
    );
    assert!(!f.core.close_event_subscription(&sub.token).unwrap());
}

#[test]
fn qualification_default_heartbeat_capacity_preserves_sequence_on_overflow() {
    let mut f = fixture(1, [vec![], vec![]]);
    let sub = f.core.open_event_subscription().unwrap();
    let cursor = sub.snapshot.event_cursor;
    for _ in 0..256 {
        f.core.emit_heartbeat().unwrap();
        assert!(f.core.event_subscription_active(&sub.token).unwrap());
    }
    f.core.emit_heartbeat().unwrap();
    assert_eq!(f.core.poll_event(&sub.token).unwrap(), EventPoll::Closed);
    assert_eq!(
        f.core
            .open_event_subscription()
            .unwrap()
            .snapshot
            .event_cursor,
        cursor
    );
}
