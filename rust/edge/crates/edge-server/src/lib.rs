#![forbid(unsafe_code)]
//! Private filesystem UDS HTTP/1 transport. A dedicated thread owns Core and its
//! executor; only typed Send messages cross the transport boundary. The caller
//! supplies the inherited listener and trusted expected UID. Socket ownership,
//! discovery, deployment policy, and business retry decisions belong elsewhere.
mod control;
mod http;
mod limits;
mod peer;
mod write_deadline;
pub use control::{ControlOperation, ControlPlane, ControlReply, ControlRuntime, MonotonicClock};
pub use http::{ServerError, serve};
pub use limits::ServerLimits;
pub use peer::{LinuxPeerCredentials, PeerCredentials};
