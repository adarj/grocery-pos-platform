#![forbid(unsafe_code)]
//! Repository-only synthetic process fixture, never a production daemon.
use edge_adapter_api::{
    AdapterErrorCode, DeviceAdapter, EffectClass, ObservationPoll, ObservationSource,
};
use edge_core::*;
use edge_protocol::*;
use edge_server::*;
use edge_sim::{
    ObservationStep, Script, ScriptedAdapter, ScriptedObservationSource, ScriptedOperation, Step,
};
use serde::Deserialize;
use std::{
    cell::Cell, collections::BTreeSet, io::Read, path::PathBuf, rc::Rc, sync::Arc, time::Duration,
};

#[derive(Clone, Copy, Eq, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Scenario {
    Success,
    Pending,
    Panic,
    PossibleFailure,
    Rejected,
    BindingLost,
}

#[derive(Eq, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct Payload {
    scenario: Scenario,
    token: u8,
}

impl StrictJsonSchema for Payload {}
impl TypedCommandPayload for Payload {
    fn command_kind(&self) -> &'static str {
        "synthetic.signal"
    }
}

impl CoreCommand for Payload {
    type PayloadFingerprint = (Scenario, u8);
    fn required_capability(&self) -> &'static str {
        "synthetic.signal"
    }

    fn effect_class(&self) -> EffectClass {
        EffectClass::DiscreteEffect
    }

    fn retained_payload_fingerprint(&self) -> Self::PayloadFingerprint {
        (self.scenario, self.token)
    }
}

struct Decoder;

impl CommandPayloadDecoder for Decoder {
    type Payload = Payload;
    fn decode_payload(
        kind: &CommandKind,
        payload: StrictJsonFragment<'_>,
    ) -> Result<Payload, CommandPayloadDecodeError> {
        if kind.as_str() != "synthetic.signal" {
            return Err(CommandPayloadDecodeError::UnknownKind);
        }
        let payload: Payload = payload.decode()?;
        // Repository-only synthetic constraint exercises the 422 distinction.
        if payload.token == 0 {
            return Err(CommandPayloadDecodeError::SemanticViolation);
        }
        Ok(payload)
    }
}

struct Adapter {
    begins: Rc<Cell<usize>>,
}

impl DeviceAdapter<Payload> for Adapter {
    type Operation = ScriptedOperation<Payload>;
    fn begin(&mut self, payload: Arc<Payload>) -> Result<Self::Operation, AdapterErrorCode> {
        self.begins.set(self.begins.get() + 1);
        let failure = AdapterErrorCode::new("sim.synthetic_failure");
        let steps = match payload.scenario {
            Scenario::Success => vec![
                Step::MarkPossible,
                Step::MarkConfirmed,
                Step::CompleteSuccess,
            ],
            Scenario::Pending => vec![Step::StallForever],
            Scenario::Panic => vec![Step::MarkPossible, Step::Panic],
            Scenario::PossibleFailure => vec![Step::MarkPossible, Step::CompleteFailed(failure)],
            Scenario::Rejected => vec![Step::CompleteRejected(failure)],
            Scenario::BindingLost => vec![Step::MarkPossible, Step::BindingLost(failure)],
        };
        let (mut adapter, _) = ScriptedAdapter::new([Script::new(steps).expect("bounded fixture")])
            .expect("bounded fixture");
        adapter.begin(payload)
    }
}
type Runtime = ControlRuntime<Payload, MonotonicClock, Adapter>;

struct Observations {
    source: ScriptedObservationSource,
    release: PathBuf,
    published: Rc<Cell<usize>>,
}

impl ObservationSource for Observations {
    fn poll(&mut self) -> ObservationPoll {
        if !self.release.exists() {
            return ObservationPoll::Pending;
        }
        let poll = self.source.poll();
        if matches!(poll, ObservationPoll::Observation(_)) {
            self.published.set(self.published.get() + 1);
        }
        poll
    }
}

struct Fixture {
    runtime: Runtime,
    observations: ObservationSupervisor<Observations>,
    observation_count: Rc<Cell<usize>>,
    begins: Rc<Cell<usize>>,
    metrics: PathBuf,
    posts: usize,
    dedup: usize,
    requests_total: usize,
    command_high_water: usize,
    requests: Vec<RequestId>,
    flood: bool,
    flood_left: usize,
    flood_start: Option<std::time::Instant>,
    rebind: bool,
    compatibility_v1_0: bool,
    drive_release: Option<PathBuf>,
}

impl Fixture {
    fn metrics(&self) {
        // Only authored counters and request-attempt correlation, no payloads.
        let ids = self
            .requests
            .iter()
            .map(|s| s.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        let value = format!(
            "{}\n{}\n{}\n{}\nrequests_total={}\nretained={}\ncommand_high_water={}\nobservations={}\n",
            self.posts,
            self.dedup,
            self.begins.get(),
            ids,
            self.requests_total,
            self.runtime.core.retained_command_count(),
            self.command_high_water,
            self.observation_count.get()
        );
        let next = self.metrics.with_extension("next");
        std::fs::write(&next, value).expect("fixture metric file");
        std::fs::rename(next, &self.metrics).expect("fixture metric publication");
    }
}

impl ControlPlane<Payload> for Fixture {
    fn request(&mut self, op: ControlOperation<Payload>) -> Result<ControlReply, CoreFatalError> {
        self.requests_total += 1;
        if let ControlOperation::Submit(sub) = &op {
            self.posts += 1;
            if self.requests.len() < 64 {
                self.requests.push(sub.request_id.clone());
            }
        }
        let mut result = self.runtime.request(op)?;
        // Qualification-only legacy metadata; production always reports CURRENT.
        if self.compatibility_v1_0
            && let ControlReply::Status(status) = &mut result
        {
            status.protocol_version = ProtocolVersion::V1;
        }
        if matches!(
            &result,
            ControlReply::Admission(AdmissionDecision::Deduplicated(_))
        ) {
            self.dedup += 1;
        }
        self.command_high_water = self
            .command_high_water
            .max(self.runtime.core.retained_command_count());
        self.metrics();
        Ok(result)
    }

    fn event_cursor(&self) -> u64 {
        self.runtime.event_cursor()
    }

    fn subscription_active(&self, t: &SubscriptionToken) -> Result<bool, CoreFatalError> {
        self.runtime.subscription_active(t)
    }

    fn drive(&mut self) -> Result<(), CoreFatalError> {
        // Explicit qualification modes model delayed executor scheduling without
        // blocking HTTP admission or changing the production executor cadence.
        if let Some(release) = &self.drive_release {
            if !release.exists() {
                return Ok(());
            }
            self.drive_release = None;
        }
        self.runtime.drive()?;
        self.observations.drive(&mut self.runtime.core)?;
        if self.rebind && self.posts >= 2 && self.begins.get() > 0 {
            self.rebind = false;
            let device = DeviceId::new("fixture.device").unwrap();
            let old = BindingInstanceId::new("fixture-binding-a").unwrap();
            self.runtime
                .core
                .invalidate_binding(&device, &old, BindingInvalidation::Disconnected)
                .unwrap();
            // Contain old active/waiting work before installing fresh hardware.
            self.runtime.drive()?;
            self.runtime.core.begin_connecting(&device).unwrap();
            let witness = self
                .runtime
                .executor
                .install_binding(
                    &mut self.runtime.core,
                    &device,
                    &BindingInstanceId::new("fixture-binding-b").unwrap(),
                    [(
                        ResourceId::new(7),
                        Adapter {
                            begins: self.begins.clone(),
                        },
                    )],
                )
                .unwrap();
            self.runtime
                .core
                .activate_binding(witness, bound())
                .unwrap();
        }
        if self.flood_left > 0
            && self
                .flood_start
                .is_some_and(|start| start.elapsed() >= Duration::from_millis(200))
        {
            self.flood_left -= 1;
            let mut state = bound();
            state.availability = if self.flood_left.is_multiple_of(2) {
                BoundAvailability::Ready
            } else {
                BoundAvailability::Degraded
            };
            state.conditions = (0..256)
                .map(|i| {
                    ConditionCode::new(format!("sim.condition.{i:03}.{}", "x".repeat(100))).unwrap()
                })
                .collect();
            self.runtime
                .core
                .update_bound_device_state(
                    &DeviceId::new("fixture.device").unwrap(),
                    &BindingInstanceId::new("fixture-binding-a").unwrap(),
                    state,
                )
                .unwrap();
        }
        self.metrics();
        Ok(())
    }

    fn heartbeat(&mut self) -> Result<(), CoreFatalError> {
        self.runtime.heartbeat()
    }

    fn open_events(&mut self) -> Result<EventSubscription, SubscriptionError> {
        let sub = self.runtime.open_events()?;
        if self.flood {
            self.flood_left = 200;
            self.flood_start = Some(std::time::Instant::now());
        }
        Ok(sub)
    }

    fn poll_events(&mut self, t: &SubscriptionToken) -> Result<EventPoll, CoreFatalError> {
        self.runtime.poll_events(t)
    }

    fn close_events(&mut self, t: &SubscriptionToken) -> Result<bool, CoreFatalError> {
        self.runtime.close_events(t)
    }
}

fn bound() -> BoundDeviceState {
    BoundDeviceState {
        availability: BoundAvailability::Ready,
        conditions: BTreeSet::new(),
        capabilities: [Capability::new("synthetic.signal").unwrap()].into(),
    }
}

fn listener(socket: &std::path::Path, mode: &str) -> std::os::unix::net::UnixListener {
    if matches!(mode, "startup-paused" | "startup-exit") {
        // Hold open the bind-before-listen window in std UnixListener::bind.
        // Only this explicitly selected repository fixture mode changes startup.
        let fd = rustix::net::socket_with(
            rustix::net::AddressFamily::UNIX,
            rustix::net::SocketType::STREAM,
            rustix::net::SocketFlags::CLOEXEC,
            None,
        )
        .expect("fixture socket");
        let address = rustix::net::SocketAddrUnix::new(socket).expect("fixture address");
        rustix::net::bind(&fd, &address).expect("fixture bind");
        if mode == "startup-exit" {
            eprintln!("fixture startup exit requested");
            std::process::exit(23);
        }
        let mut release = [0];
        if std::io::stdin().read_exact(&mut release).is_err() {
            std::process::exit(24);
        }
        rustix::net::listen(&fd, -1).expect("fixture listen");
        // A second gate distinguishes a listening socket from responsive HTTP.
        std::fs::write(socket.with_extension("listening"), b"")
            .expect("fixture startup observation");
        if std::io::stdin().read_exact(&mut release).is_err() {
            std::process::exit(24);
        }
        return fd.into();
    }
    std::os::unix::net::UnixListener::bind(socket).expect("fixture-owned temporary UDS")
}

fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.len() < 3 {
        eprintln!(
            "usage: edge-qualification-fixture SOCKET METRICS AGENT [lost|flood|rebind|small]"
        );
        std::process::exit(2);
    }
    let socket = PathBuf::from(&args[0]);
    let metrics = PathBuf::from(&args[1]);
    let agent = AgentInstanceId::new(&args[2]).expect("fixture agent");
    let mode = args.get(3).cloned().unwrap_or_default();
    let listener = listener(&socket, &mode);
    let uid = rustix::process::getuid().as_raw();
    let mut limits = ServerLimits {
        heartbeat_interval: Duration::from_millis(100),
        lose_first_accepted_response: matches!(mode.as_str(), "lost" | "lost-paused-drive"),
        event_chunk_bytes: 17,
        ..ServerLimits::default()
    };
    if matches!(mode.as_str(), "small" | "small-paused-drive") {
        limits.max_connections = 2;
        limits.control_mailbox_capacity = 1;
    }
    let (stop, shutdown) = tokio::sync::oneshot::channel();
    let input = std::thread::spawn(move || {
        let mut byte = [0u8; 1];
        let _ = std::io::stdin().read(&mut byte);
        let _ = stop.send(());
    });
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let result = runtime.block_on(serve::<Payload, Decoder, _, _, _>(
        listener,
        uid,
        LinuxPeerCredentials,
        limits,
        move || {
            let begins = Rc::new(Cell::new(0));
            let mut core_limits = CoreLimits::with_registry_bounds(1, 1, 2, 256);
            if mode == "cache" {
                core_limits.max_command_records = 1;
            }
            core_limits.max_event_queue_records = if mode == "flood" { 2 } else { 256 };
            let (producer, consumer) = bounded_executor_queue(
                [ResourceId::new(7)],
                1,
                if matches!(mode.as_str(), "small" | "small-paused-drive") {
                    1
                } else {
                    32
                },
            )?;
            let device = DeviceId::new("fixture.device").unwrap();
            let binding = BindingInstanceId::new("fixture-binding-a").unwrap();
            let seed = CoreDeviceSeed {
                snapshot: DeviceSnapshot {
                    agent_instance_id: agent.clone(),
                    device_id: device.clone(),
                    binding_instance_id: None,
                    state_revision: StateRevision::new(0),
                    adapter_kind: AdapterKind::new("synthetic.scripted").unwrap(),
                    availability: DeviceAvailability::Absent,
                    conditions: BTreeSet::new(),
                    capabilities: BTreeSet::new(),
                },
                allowed_capabilities: if mode == "observations" {
                    vec![
                        Capability::new("synthetic.signal").unwrap(),
                        Capability::new("scanner.barcode").unwrap(),
                    ]
                } else {
                    vec![Capability::new("synthetic.signal").unwrap()]
                },
                capability_resources: vec![(
                    Capability::new("synthetic.signal").unwrap(),
                    ResourceId::new(7),
                )],
            };
            let mut core = CoreActor::new(
                agent,
                vec![seed],
                core_limits,
                MonotonicClock::default(),
                producer,
            )?;
            core.begin_connecting(&device).unwrap();
            let mut executor = ExecutorSupervisor::new(consumer)?;
            let mut witness = executor
                .install_binding(
                    &mut core,
                    &device,
                    &binding,
                    [(
                        ResourceId::new(7),
                        Adapter {
                            begins: begins.clone(),
                        },
                    )],
                )
                .unwrap();
            let mut observations = ObservationSupervisor::new();
            let observation_count = Rc::new(Cell::new(0));
            let mut state = bound();
            if mode == "observations" {
                let caps = BTreeSet::from([Capability::new("scanner.barcode").unwrap()]);
                let script = ["049000001234", "049000001234", "other"]
                    .into_iter()
                    .map(|v| {
                        ObservationStep::Poll(ObservationPoll::Observation(
                            DeviceObservation::ScannerBarcode {
                                barcode: BarcodeValue::new(v).unwrap(),
                            },
                        ))
                    });
                let source = Observations {
                    source: ScriptedObservationSource::new(script).unwrap(),
                    release: metrics.with_extension("observations"),
                    published: observation_count.clone(),
                };
                let proof = observations
                    .install_binding(&mut core, &device, &binding, caps.clone(), source)
                    .unwrap();
                witness = witness.combine(proof).unwrap();
                state.capabilities.extend(caps);
            }
            core.activate_binding(witness, state).unwrap();
            let drive_release = matches!(mode.as_str(), "lost-paused-drive" | "small-paused-drive")
                .then(|| metrics.with_extension("resume"));
            let f = Fixture {
                runtime: ControlRuntime { core, executor },
                observations,
                observation_count,
                begins,
                metrics,
                posts: 0,
                dedup: 0,
                requests_total: 0,
                command_high_water: 0,
                requests: vec![],
                flood: mode == "flood",
                flood_left: 0,
                flood_start: None,
                rebind: mode == "rebind",
                compatibility_v1_0: mode == "version-1-0",
                drive_release,
            };
            f.metrics();
            Ok(f)
        },
        async {
            let _ = shutdown.await;
        },
    ));
    if result.is_err() {
        eprintln!("fixture control epoch stopped");
        std::process::exit(1);
    }
    let _ = input.join();
    let _ = std::fs::remove_file(socket);
}
