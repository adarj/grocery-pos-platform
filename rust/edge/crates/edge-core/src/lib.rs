#![forbid(unsafe_code)]

//! Exclusive, deterministic Edge command admission. This crate owns no executor,
//! device I/O, HTTP server, event stream, or POS business truth.

mod actor;
mod model;
mod queue;

pub use actor::CoreActor;
pub use model::{
    AdmissionDecision, AdmissionRejection, AgentClock, CoreCommand, CoreDeviceSeed, CoreFatalError,
    CoreLimits, ResourceId,
};
pub use queue::{ExecutorQueuePort, QueueCommitError, QueueReservationError, QueuedCommand};
