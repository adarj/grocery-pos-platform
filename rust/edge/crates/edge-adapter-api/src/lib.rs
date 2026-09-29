#![forbid(unsafe_code)]

//! Device-semantic execution contract, with no Core, JSON, transport, or business
//! authority. In-process containment is conditional on bounded adapter calls:
//! neither begin, poll, nor Drop may block indefinitely or launch autonomous I/O.
//! Destructors must not panic or initiate semantic effects. A destructor panic
//! violates safe cleanup and requires process termination, not an ordinary
//! command outcome. Rust may abort during double-panic unwinding; this contract
//! does not promise containment of arbitrary destructors.
//! A driver that cannot honor this requires a different isolation boundary.

use std::sync::Arc;

use edge_protocol::NonterminalCommandState;

/// Compiled command metadata, never caller-selected wire input or retry policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EffectClass {
    Observation,
    ReplaceableState,
    DiscreteEffect,
}

/// Authored adapter diagnostics only. The static lifetime prevents borrowing
/// device traffic; adapters must use literal semantic codes, never leaked or
/// formatted external text. Core maps these to bounded public ErrorCode values.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AdapterErrorCode(&'static str);

impl AdapterErrorCode {
    /// Invalid authored constants are programming errors (and fail const
    /// evaluation when used as constants), never a device-input error path.
    pub const fn new(code: &'static str) -> Self {
        assert!(
            !code.is_empty() && code.len() <= edge_protocol::MAX_SEMANTIC_NAME_BYTES,
            "adapter error code must be a bounded authored constant"
        );
        Self(code)
    }

    pub const fn as_str(self) -> &'static str {
        self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EffectContractViolation;

/// Restricted monotonic progress. mark_possible MUST occur immediately before
/// the first action after which the semantic effect could have happened.
/// mark_confirmed requires the command-specific success criterion and a prior
/// mark_possible. There is no reset or arbitrary evidence setter.
pub trait EffectProgress {
    fn mark_possible(&mut self);
    fn mark_confirmed(&mut self) -> Result<(), EffectContractViolation>;
}

/// The executor supplies a read-only witness of the existing executing record.
/// Adapters cannot mutate lifecycle, binding identity, or public outcomes.
/// Progress is borrowed for this poll only; it cannot be retained by an
/// operation and used after timeout or terminal publication.
///
/// ```compile_fail
/// use edge_adapter_api::{AdapterOperation, AdapterPoll, AdapterPollContext, EffectProgress};
/// struct Operation {
///     stale: Option<&'static mut dyn EffectProgress>,
/// }
/// impl AdapterOperation for Operation {
///     fn poll(&mut self, context: &mut AdapterPollContext<'_>) -> AdapterPoll {
///         self.stale = Some(context.effects); // the poll borrow cannot escape
///         AdapterPoll::Pending
///     }
/// }
/// ```
pub struct AdapterPollContext<'a> {
    pub record: &'a NonterminalCommandState,
    pub effects: &'a mut dyn EffectProgress,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdapterPoll {
    Pending,
    Succeeded,
    RejectedBeforeEffect(AdapterErrorCode),
    KnownFailure(AdapterErrorCode),
    BindingLost(AdapterErrorCode),
}

/// Each poll performs bounded work and returns. No autonomous/background
/// physical effects may remain running after return. Dropping an operation
/// guarantees no future device I/O, including from destructors or worker tasks.
/// Drop must return in bounded time, must not panic, and must not initiate the
/// requested effect. Cleanup may close handles or discard transport state.
/// All potentially effectful actions use the supplied restricted handle.
pub trait AdapterOperation {
    fn poll(&mut self, context: &mut AdapterPollContext<'_>) -> AdapterPoll;
}

/// begin only constructs an operation: it MUST NOT perform effectful I/O.
/// begin and adapter Drop must return in bounded time. Dropping a fenced
/// adapter closes/discards its transport and performs no further effectful I/O.
/// Adapter Drop must not panic or initiate the requested effect.
/// Payload ownership belongs to the operation: release every strong reference
/// when it is dropped, and never retain payloads in adapter caches or diagnostics.
pub trait DeviceAdapter<P> {
    type Operation: AdapterOperation;

    fn begin(&mut self, payload: Arc<P>) -> Result<Self::Operation, AdapterErrorCode>;
}
