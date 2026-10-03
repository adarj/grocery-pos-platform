mod support;

use std::cell::{Cell, RefCell};
use std::collections::{BTreeSet, VecDeque};
use std::rc::Rc;
use std::sync::Arc;

use edge_adapter_api::*;
use edge_core::*;
use edge_protocol::*;
use edge_supervisor::binding::*;
use edge_supervisor::config::*;
use edge_supervisor::discovery::*;
use support::*;

#[derive(Eq, PartialEq)]
struct Payload;
impl TypedCommandPayload for Payload {
    fn command_kind(&self) -> &'static str {
        "synthetic.signal"
    }
}

impl CoreCommand for Payload {
    type PayloadFingerprint = ();
    fn required_capability(&self) -> &'static str {
        self.command_kind()
    }

    fn effect_class(&self) -> EffectClass {
        EffectClass::DiscreteEffect
    }

    fn retained_payload_fingerprint(&self) {}
}

struct Clock;
impl AgentClock for Clock {
    fn now(&self) -> AgentUptimeMs {
        AgentUptimeMs::new(100)
    }
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
    fn poll(&mut self, _: &mut AdapterPollContext<'_>) -> AdapterPoll {
        AdapterPoll::Pending
    }
}

struct Source {
    attached: Rc<Cell<bool>>,
    drops: Rc<Cell<usize>>,
}

impl ObservationSource for Source {
    fn poll(&mut self) -> ObservationPoll {
        if self.attached.get() {
            ObservationPoll::Pending
        } else {
            ObservationPoll::BindingLost(AdapterErrorCode::new("sim.lost"))
        }
    }
}

impl Drop for Source {
    fn drop(&mut self) {
        self.drops.set(self.drops.get() + 1);
    }
}

struct Factory {
    attached: Rc<Cell<bool>>,
    drops: Rc<Cell<usize>>,
    fail: bool,
    panic: bool,
}

impl RuntimeFactory<Payload> for Factory {
    type CommandAdapter = Adapter;
    type Observations = Source;
    fn prepare(
        &mut self,
        slot: &ConfiguredSlot,
        _: &DiscoveryCandidate,
        _: &[(Capability, ResourceId)],
    ) -> Result<PreparedRuntime<Adapter, Source>, PreparationError> {
        assert!(!self.panic, "PRIVATE_DEVICE_DATA");
        if self.fail {
            return Err(PreparationError::Unavailable);
        }
        Ok(PreparedRuntime::new(
            vec![],
            Some((
                [Capability::new("scanner.barcode").unwrap()].into(),
                Source {
                    attached: self.attached.clone(),
                    drops: self.drops.clone(),
                },
            )),
            BoundDeviceState {
                availability: BoundAvailability::Ready,
                conditions: BTreeSet::new(),
                capabilities: slot.allowed_capabilities().clone(),
            },
        ))
    }

    fn check_attachment(
        &mut self,
        _: &ConfiguredSlot,
        prepared: &PreparedRuntime<Adapter, Source>,
        _: &DiscoveryCandidate,
    ) -> Result<(), PreparationError> {
        if prepared.observation_source().unwrap().attached.get() {
            Ok(())
        } else {
            Err(PreparationError::Unavailable)
        }
    }
}

struct Ids(usize);
impl BindingIdSource for Ids {
    fn next_id(&mut self) -> Result<BindingInstanceId, PreparationError> {
        self.0 += 1;
        Ok(BindingInstanceId::new(format!("binding-{}", self.0)).unwrap())
    }
}

type Scan = Result<DiscoverySnapshot, DiscoveryError>;
#[derive(Clone)]
struct Discovery(Rc<RefCell<VecDeque<Scan>>>);
impl DiscoverySource for Discovery {
    fn snapshot(&self) -> Scan {
        self.0
            .borrow_mut()
            .pop_front()
            .expect("explicit fresh scan required")
    }
}

type Core = CoreActor<Payload, Clock, QueueProducer<Payload>>;
type Registry = RuntimeFactoryRegistry<Payload, Adapter, Source>;
type FactoryEntry =
    Box<dyn RuntimeFactory<Payload, CommandAdapter = Adapter, Observations = Source>>;
type Manager = BindingManager<Discovery, Registry, Ids>;
type Fixture = (
    Core,
    ExecutorSupervisor<Payload, Adapter>,
    ObservationSupervisor<Source>,
    Manager,
    Rc<Cell<usize>>,
    Rc<Cell<bool>>,
    Discovery,
);
fn scan(candidates: Vec<DiscoveryCandidate>) -> Scan {
    DiscoverySnapshot::new(candidates)
}

fn setup(config: Configuration, scans: Vec<Scan>) -> Fixture {
    let agent = AgentInstanceId::new("agent").unwrap();
    let seeds = config.core_seeds(&agent);
    let resources: BTreeSet<_> = seeds
        .iter()
        .flat_map(|s| s.capability_resources.iter().map(|(_, r)| *r))
        .collect();
    let (producer, consumer) = bounded_executor_queue(resources, 32, 32).unwrap();
    let core = CoreActor::new(
        agent,
        seeds,
        CoreLimits::with_registry_bounds(32, 32, 32, 32),
        Clock,
        producer,
    )
    .unwrap();
    let discovery = Discovery(Rc::new(RefCell::new(scans.into())));
    let drops = Rc::new(Cell::new(0));
    let attached = Rc::new(Cell::new(true));
    let manager = BindingManager::new(
        config,
        discovery.clone(),
        Registry::new(
            &catalog(),
            [(
                AdapterKind::new("example.scanner").unwrap(),
                Box::new(Factory {
                    drops: drops.clone(),
                    attached: attached.clone(),
                    fail: false,
                    panic: false,
                }) as FactoryEntry,
            )],
        )
        .unwrap(),
        Ids(0),
    );
    (
        core,
        ExecutorSupervisor::new(consumer).unwrap(),
        ObservationSupervisor::new(),
        manager,
        drops,
        attached,
        discovery,
    )
}

fn id(s: &str) -> DeviceId {
    DeviceId::new(s).unwrap()
}

#[test]
fn catalog_metadata_is_not_an_operational_factory_and_registry_duplicates_fail() {
    let configuration = config(&[slot("scanner", true, "")]);
    let (mut core, mut executor, mut observations, _, drops, attached, discovery) = setup(
        configuration.clone(),
        vec![scan(vec![candidate("a", None, 1)])],
    );
    let registry = Registry::new(&catalog(), []).unwrap();
    let mut manager = BindingManager::new(configuration, discovery, registry, Ids(0));
    assert_eq!(
        manager.reconcile(&mut core, &mut executor, &mut observations),
        Err(BindingError::Preparation(PreparationError::Unavailable))
    );
    let device = core.device_snapshot(&id("scanner")).unwrap();
    assert!(device.binding_instance_id.is_none());
    assert!(
        device
            .conditions
            .contains(&ConditionCode::new("edge.binding_preparation_failed").unwrap())
    );
    let entry = || {
        Box::new(Factory {
            drops: drops.clone(),
            attached: attached.clone(),
            fail: false,
            panic: false,
        }) as FactoryEntry
    };
    assert!(
        Registry::new(
            &catalog(),
            [(AdapterKind::new("unknown").unwrap(), entry())]
        )
        .is_err()
    );
    assert!(
        Registry::new(
            &catalog(),
            [
                (AdapterKind::new("example.scanner").unwrap(), entry()),
                (AdapterKind::new("example.scanner").unwrap(), entry())
            ]
        )
        .is_err()
    );
}

#[test]
fn preparation_panics_are_authored_private_failures_not_binding_authority() {
    let configuration = config(&[slot("scanner", true, "")]);
    let (mut core, mut executor, mut observations, _, drops, attached, discovery) = setup(
        configuration.clone(),
        vec![scan(vec![candidate("a", None, 1)])],
    );
    let registry = Registry::new(
        &catalog(),
        [(
            AdapterKind::new("example.scanner").unwrap(),
            Box::new(Factory {
                drops,
                attached,
                fail: false,
                panic: true,
            }) as FactoryEntry,
        )],
    )
    .unwrap();
    let mut manager = BindingManager::new(configuration, discovery, registry, Ids(0));
    assert_eq!(
        manager.reconcile(&mut core, &mut executor, &mut observations),
        Err(BindingError::Preparation(PreparationError::Panic))
    );
    assert!(
        core.device_snapshot(&id("scanner"))
            .unwrap()
            .binding_instance_id
            .is_none()
    );
}

#[test]
fn fresh_revalidation_rejects_absence_ambiguity_replacement_and_malformed_scan() {
    let a = candidate("a", Some("one"), 1);
    for fresh in [
        scan(vec![]),
        scan(vec![a.clone(), candidate("b", None, 2)]),
        scan(vec![candidate("b", None, 2)]),
        // Snapshot-local IDs can be reused. Changed attachment facts are not
        // sufficient even when a broad selector still uniquely matches it.
        scan(vec![candidate("a", Some("replacement"), 1)]),
        Err(DiscoveryError::InvalidAttribute),
    ] {
        let (mut core, mut executor, mut observations, mut manager, drops, _, _) = setup(
            config(&[slot("scanner", true, "")]),
            vec![scan(vec![a.clone()]), fresh],
        );
        let result = manager.reconcile(&mut core, &mut executor, &mut observations);
        assert!(
            result.is_ok()
                || matches!(
                    result,
                    Err(BindingError::Discovery(DiscoveryError::InvalidAttribute))
                )
        );
        assert!(
            core.device_snapshot(&id("scanner"))
                .unwrap()
                .binding_instance_id
                .is_none()
        );
        assert_eq!(drops.get(), 1); // prepared ownership discarded, not installed
        assert!(observations.publication_token(&id("scanner")).is_none());
    }
}

#[test]
fn global_conflict_appearing_during_preparation_rejects_every_claim() {
    // A is unique while B is ambiguous. Removing Y makes B uniquely claim X,
    // so A's preparation must be discarded by the fresh *global* reconciliation.
    let x = candidate("x", Some("one"), 1);
    let y = candidate("y", Some("two"), 2);
    let configuration = config(&[slot("a", true, "serial = \"one\""), slot("b", true, "")]);
    let (mut core, mut executor, mut observations, mut manager, drops, _, _) =
        setup(configuration, vec![scan(vec![x.clone(), y]), scan(vec![x])]);
    manager
        .reconcile(&mut core, &mut executor, &mut observations)
        .unwrap();
    assert_eq!(drops.get(), 1);
    for name in ["a", "b"] {
        assert!(
            core.device_snapshot(&id(name))
                .unwrap()
                .binding_instance_id
                .is_none()
        );
    }
    assert!(
        core.device_snapshot(&id("a"))
            .unwrap()
            .conditions
            .contains(&ConditionCode::new("edge.discovery_conflict").unwrap())
    );
}

#[test]
fn same_candidate_must_also_have_a_current_owned_attachment() {
    let a = candidate("a", None, 1);
    let (mut core, mut executor, mut observations, mut manager, drops, attached, _) = setup(
        config(&[slot("scanner", true, "")]),
        vec![scan(vec![a.clone()]), scan(vec![a])],
    );
    // Identical sysfs identity can be reused; preparation's handle is still lost.
    attached.set(false);
    assert_eq!(
        manager.reconcile(&mut core, &mut executor, &mut observations),
        Err(BindingError::Preparation(PreparationError::Unavailable))
    );
    assert_eq!(drops.get(), 1);
    assert!(
        core.device_snapshot(&id("scanner"))
            .unwrap()
            .binding_instance_id
            .is_none()
    );
}

#[test]
fn unchanged_attachment_binds_then_disconnect_rebind_has_fresh_epoch() {
    let a = candidate("a", None, 1);
    let (mut core, mut executor, mut observations, mut manager, drops, _, scans) = setup(
        config(&[slot("scanner", true, "")]),
        vec![
            scan(vec![a.clone()]),
            scan(vec![a.clone()]),
            scan(vec![]),
            scan(vec![a.clone()]),
            scan(vec![a]),
        ],
    );
    manager
        .reconcile(&mut core, &mut executor, &mut observations)
        .unwrap();
    let first = core
        .device_snapshot(&id("scanner"))
        .unwrap()
        .binding_instance_id
        .clone()
        .unwrap();
    let old = observations.publication_token(&id("scanner")).unwrap();
    manager
        .reconcile(&mut core, &mut executor, &mut observations)
        .unwrap();
    assert_eq!(drops.get(), 1);
    assert_eq!(
        core.device_snapshot(&id("scanner")).unwrap().availability,
        DeviceAvailability::Absent
    );
    manager
        .reconcile(&mut core, &mut executor, &mut observations)
        .unwrap();
    let second = core
        .device_snapshot(&id("scanner"))
        .unwrap()
        .binding_instance_id
        .clone()
        .unwrap();
    assert_ne!(first, second);
    assert!(scans.0.borrow().is_empty());
    let cursor = core.event_cursor();
    assert_eq!(
        core.publish_observation(
            &old,
            DeviceObservation::ScannerBarcode {
                barcode: BarcodeValue::new("0").unwrap()
            }
        )
        .unwrap(),
        ObservationDisposition::Fenced
    );
    assert_eq!(core.event_cursor(), cursor);
}

#[test]
fn later_ambiguity_conflict_or_failed_scan_withdraws_current_authority() {
    let a = candidate("a", Some("one"), 1);
    let b = candidate("b", Some("two"), 2);
    for fresh in [scan(vec![a.clone(), b.clone()]), Err(DiscoveryError::Io)] {
        let scan_failed = matches!(fresh, Err(DiscoveryError::Io));
        let (mut core, mut executor, mut observations, mut manager, drops, _, _) = setup(
            config(&[slot("scanner", true, "")]),
            vec![scan(vec![a.clone()]), scan(vec![a.clone()]), fresh],
        );
        manager
            .reconcile(&mut core, &mut executor, &mut observations)
            .unwrap();
        let result = manager.reconcile(&mut core, &mut executor, &mut observations);
        if scan_failed {
            assert_eq!(result, Err(BindingError::Discovery(DiscoveryError::Io)));
            assert!(
                core.device_snapshot(&id("scanner"))
                    .unwrap()
                    .conditions
                    .contains(&ConditionCode::new("edge.discovery_failed").unwrap())
            );
        }
        assert_eq!(drops.get(), 1);
        assert!(
            core.device_snapshot(&id("scanner"))
                .unwrap()
                .binding_instance_id
                .is_none()
        );
    }
    let configuration = config(&[slot("a", true, "serial = \"one\""), slot("b", true, "")]);
    let (mut core, mut executor, mut observations, mut manager, drops, _, _) = setup(
        configuration,
        vec![
            scan(vec![a.clone(), b.clone()]),
            scan(vec![a.clone(), b]),
            scan(vec![a]),
        ],
    );
    manager
        .reconcile(&mut core, &mut executor, &mut observations)
        .unwrap();
    manager
        .reconcile(&mut core, &mut executor, &mut observations)
        .unwrap();
    assert_eq!(drops.get(), 1);
    for name in ["a", "b"] {
        let d = core.device_snapshot(&id(name)).unwrap();
        assert!(d.binding_instance_id.is_none());
        assert!(
            d.conditions
                .contains(&ConditionCode::new("edge.discovery_conflict").unwrap())
        );
    }
}

#[test]
fn source_reported_loss_is_reconciled_as_a_new_attachment_not_transferred_epoch() {
    let a = candidate("a", None, 1);
    let (mut core, mut executor, mut observations, mut manager, drops, attached, _) = setup(
        config(&[slot("scanner", true, "")]),
        vec![
            scan(vec![a.clone()]),
            scan(vec![a.clone()]),
            scan(vec![a.clone()]),
            scan(vec![a]),
        ],
    );
    manager
        .reconcile(&mut core, &mut executor, &mut observations)
        .unwrap();
    let old = core
        .device_snapshot(&id("scanner"))
        .unwrap()
        .binding_instance_id
        .clone();
    attached.set(false);
    observations.drive(&mut core).unwrap();
    assert_eq!(drops.get(), 1);
    attached.set(true);
    manager
        .reconcile(&mut core, &mut executor, &mut observations)
        .unwrap();
    assert_ne!(
        core.device_snapshot(&id("scanner"))
            .unwrap()
            .binding_instance_id,
        old
    );
}

#[test]
fn unbound_lifecycle_reports_disabled_absent_ambiguous_and_conflict() {
    for (slots, candidates, availability, condition) in [
        (
            vec![slot("scanner", false, "")],
            vec![candidate("a", None, 1)],
            DeviceAvailability::Disabled,
            None,
        ),
        (
            vec![slot("scanner", true, "")],
            vec![],
            DeviceAvailability::Absent,
            None,
        ),
        (
            vec![slot("scanner", true, "")],
            vec![candidate("a", None, 1), candidate("b", None, 2)],
            DeviceAvailability::Faulted,
            Some("edge.discovery_ambiguous"),
        ),
        (
            vec![slot("scanner", true, ""), slot("other", true, "")],
            vec![candidate("a", None, 1)],
            DeviceAvailability::Faulted,
            Some("edge.discovery_conflict"),
        ),
    ] {
        let (mut core, mut executor, mut observations, mut manager, drops, _, _) =
            setup(config(&slots), vec![scan(candidates)]);
        manager
            .reconcile(&mut core, &mut executor, &mut observations)
            .unwrap();
        let d = core.device_snapshot(&id("scanner")).unwrap();
        assert_eq!(d.availability, availability);
        assert_eq!(
            d.conditions.iter().next().map(ConditionCode::as_str),
            condition
        );
        assert!(d.capabilities.is_empty());
        assert!(d.binding_instance_id.is_none());
        assert_eq!(drops.get(), 0);
    }
}

#[test]
fn reused_binding_id_discards_prepared_runtime_without_polling_or_activation() {
    struct ReusedId;
    impl BindingIdSource for ReusedId {
        fn next_id(&mut self) -> Result<BindingInstanceId, PreparationError> {
            Ok(BindingInstanceId::new("binding-1").unwrap())
        }
    }
    let a = candidate("a", None, 1);
    let configuration = config(&[slot("scanner", true, "")]);
    let (mut core, mut executor, mut observations, mut first, drops, attached, discovery) = setup(
        configuration.clone(),
        vec![
            scan(vec![a.clone()]),
            scan(vec![a.clone()]),
            scan(vec![]),
            scan(vec![a.clone()]),
            scan(vec![a]),
        ],
    );
    first
        .reconcile(&mut core, &mut executor, &mut observations)
        .unwrap();
    first
        .reconcile(&mut core, &mut executor, &mut observations)
        .unwrap();
    assert_eq!(drops.get(), 1);
    let registry = Registry::new(
        &catalog(),
        [(
            AdapterKind::new("example.scanner").unwrap(),
            Box::new(Factory {
                attached,
                drops: drops.clone(),
                fail: false,
                panic: false,
            }) as FactoryEntry,
        )],
    )
    .unwrap();
    let mut second = BindingManager::new(configuration, discovery, registry, ReusedId);
    assert_eq!(
        second.reconcile(&mut core, &mut executor, &mut observations),
        Err(BindingError::Lifecycle(LifecycleError::Rejected(
            LifecycleRejection::BindingIdUsed
        )))
    );
    assert_eq!(drops.get(), 2);
    assert!(observations.publication_token(&id("scanner")).is_none());
    let before = core.event_cursor();
    observations.drive(&mut core).unwrap();
    assert_eq!(core.event_cursor(), before);
    assert!(
        core.device_snapshot(&id("scanner"))
            .unwrap()
            .binding_instance_id
            .is_none()
    );
}
