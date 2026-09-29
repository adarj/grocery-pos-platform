#![forbid(unsafe_code)]

//! Exclusive Core admission and deterministic bounded execution. No device I/O,
//! HTTP server, event stream, or POS business truth lives here.
//! In-process adapter containment requires bounded begin/poll/Drop and no
//! autonomous I/O. Executor construction wraps the process panic hook to suppress
//! adapter panic payloads; first construction belongs to serial process bootstrap.
//! Install application hooks beforehand and do not replace the wrapper afterward.
//! Core invariant panics are not caught.
//! Replacing the hook later defeats adapter-panic privacy. A panicking
//! application hook is not containable. Adapter destructors must not panic or
//! initiate effects; cleanup panic terminates the process without publishing a
//! command result. Arbitrary blocking/destructor code cannot be safely stopped
//! by this in-process contract.

mod actor;
mod effect;
mod executor;
mod fifo;
mod model;
mod panic_boundary;
mod queue;

pub use actor::CoreActor;
pub use executor::ExecutorSupervisor;
pub use fifo::{
    DEFAULT_WAITING_CAPACITY, QueueConsumer, QueueProducer, QueueReservation,
    bounded_executor_queue,
};
pub use model::{
    AdmissionDecision, AdmissionRejection, AgentClock, CoreCommand, CoreDeviceSeed, CoreFatalError,
    CoreLimits, ResourceId,
};
pub use queue::{ExecutorQueuePort, QueueCommitError, QueueReservationError, QueuedCommand};
