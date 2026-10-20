#![forbid(unsafe_code)]

//! Pure framing for the DS2208 USB CDC Host transport profile. This crate does
//! not open devices, establish physical attachment identity, install runtimes,
//! or publish observations. A decoded record is a value, not binding authority.
//!
//! Stream alignment and future runtime activation are separate facts. Opening a
//! device or activating Core does not prove that buffered bytes start a record.
//! WP2 must establish an acquisition cutoff and a justified alignment policy;
//! the framing engine implements only bounded discard-to-boundary synchronization
//! and an explicit constructor requiring external record-boundary proof.

pub mod framing;
pub mod profile;
