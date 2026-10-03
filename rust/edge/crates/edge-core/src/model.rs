use edge_protocol::{AgentUptimeMs, Capability, CommandState, DeviceSnapshot, TypedCommandPayload};

/// Private-to-Core physical serialization identity, never a wire identifier.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ResourceId(u64);

impl ResourceId {
    pub const fn new(value: u64) -> Self {
        Self(value)
    }
}

/// A compiled semantic command supplies admission metadata and an in-memory
/// compact payload identity. Capability and effect class are fixed by the
/// compiled command variant, never independently selected by request fields.
/// Payload semantics and metadata must stay immutable throughout retention and
/// execution; effect class grants no permission to retry. Fingerprints
/// must preserve the command's qualified equality semantics; they are never
/// public status or ordinary diagnostics.
pub trait CoreCommand: TypedCommandPayload + Eq + Send + Sync + 'static {
    type PayloadFingerprint: Clone + Eq + Send + Sync + 'static;

    fn required_capability(&self) -> &'static str;
    fn effect_class(&self) -> edge_adapter_api::EffectClass;
    fn retained_payload_fingerprint(&self) -> Self::PayloadFingerprint;
}

/// The daemon will derive uptime from one startup Instant; tests inject a fake.
pub trait AgentClock {
    fn now(&self) -> AgentUptimeMs;
}

/// Configured logical slot, semantic allowlist, and executable-resource subset.
/// Multiple capabilities of one device may share a resource. Resource IDs may
/// not be shared by different logical devices in this v1 admission registry.
/// Seeds are unbound, revision-zero public states. Allowed capabilities include
/// observations with no command resource; configuration alone never publishes
/// them. Both maps survive disconnect/rebind. Binding authority requires a complete
/// installed-runtime witness. In v1, unmapped allowed capabilities require an
/// observation source; mapped capabilities require command executors.
pub struct CoreDeviceSeed {
    pub snapshot: DeviceSnapshot,
    pub allowed_capabilities: Vec<Capability>,
    pub capability_resources: Vec<(Capability, ResourceId)>,
}

/// Initial M8 targets are policy defaults, not immutable wire constants.
/// Registry bounds are supplied by privileged configuration/qualification.
/// Capacity bounds and the timeout maximum must be positive. A zero submission
/// horizon permits only a deadline equal to current uptime; zero recovery age
/// still requires the original freshness deadline to have strictly passed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CoreLimits {
    pub max_devices: usize,
    pub max_resources: usize,
    pub max_capabilities_per_device: usize,
    pub max_conditions_per_device: usize,
    pub max_command_records: usize,
    pub max_submission_horizon_ms: u64,
    pub max_command_timeout_ms: u64,
    pub terminal_recovery_minimum_ms: u64,
    pub max_binding_epochs_per_agent: usize,
    pub max_event_queue_records: usize,
    pub max_event_record_bytes: usize,
}

impl CoreLimits {
    pub const fn with_registry_bounds(
        max_devices: usize,
        max_resources: usize,
        max_capabilities_per_device: usize,
        max_conditions_per_device: usize,
    ) -> Self {
        Self {
            max_devices,
            max_resources,
            max_capabilities_per_device,
            max_conditions_per_device,
            max_command_records: 4096,
            max_submission_horizon_ms: 60_000,
            max_command_timeout_ms: 60_000,
            terminal_recovery_minimum_ms: 120_000,
            // Implementation defaults requiring M8.2.7 qualification.
            max_binding_epochs_per_agent: 4096,
            max_event_queue_records: 256,
            max_event_record_bytes: edge_protocol::DEFAULT_EVENT_RECORD_MAX_BYTES,
        }
    }
}

/// Caller-visible admission decisions are values, not internal fatal errors.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdmissionRejection {
    AgentInstanceConflict,
    SemanticConflict,
    SubmissionExpired,
    SubmissionHorizonExceeded,
    TimeoutTooLarge,
    UnknownDevice,
    BindingInstanceConflict,
    CapabilityUnavailable,
    CommandCacheFull,
    ExecutorQueueFull,
    ExecutorUnavailable,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AdmissionDecision {
    Accepted(CommandState),
    Deduplicated(CommandState),
    Rejected(AdmissionRejection),
}

/// Control-plane corruption or invalid privileged seed is process-fatal, not a
/// normal protocol rejection. The future supervisor must start a new agent epoch.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CoreFatalError {
    InvalidLimits,
    TooManyDevices,
    TooManyResources,
    TooManyCapabilities,
    TooManyConditions,
    DuplicateDevice,
    RegistryAgentMismatch,
    MissingResourceMapping,
    DuplicateAllowedCapability,
    ResourceCapabilityNotAllowed,
    DuplicateResourceMapping,
    InvalidInitialDeviceState,
    ResourceSharedAcrossDevices,
    InvalidCompiledCommand,
    ClockRegression,
    RecordSequenceOverflow,
    RecordInvariant,
    QueueInvariant,
    ExecutionInvariant,
    StateRevisionOverflow,
    EventSequenceOverflow,
    SubscriptionGenerationOverflow,
    EventNotRepresentable,
    BindingInstallationInvariant,
}
