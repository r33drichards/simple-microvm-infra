//! vm-state: Manage portable MicroVM states
//!
//! This library provides a trait-based API for managing VM states backed by ZFS.
//! States are portable datasets that can be snapshotted, cloned, and migrated
//! between slots (fixed network identities).

pub mod backend;
pub mod error;
pub mod types;

pub use backend::VmStateBackend;
pub use error::{Error, Result};
pub use types::{Slot, SlotInfo, Snapshot, SnapshotInfo, State, StateInfo};
