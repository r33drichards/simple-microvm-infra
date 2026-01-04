//! Error types for vm-state

use crate::types::{Slot, State};
use thiserror::Error;

/// Result type alias for vm-state operations
pub type Result<T> = std::result::Result<T, Error>;

/// Errors that can occur during vm-state operations
#[derive(Error, Debug)]
pub enum Error {
    #[error("State '{0}' already exists")]
    StateAlreadyExists(State),

    #[error("State '{0}' does not exist")]
    StateNotFound(State),

    #[error("State '{state}' is assigned to {slot}. Reassign it first.")]
    StateInUse { state: State, slot: Slot },

    #[error("Snapshot '{0}' not found")]
    SnapshotNotFound(String),

    #[error("Slot {0} is currently running")]
    SlotRunning(Slot),

    #[error("ZFS error: {0}")]
    Zfs(String),

    #[error("Systemd error: {0}")]
    Systemd(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("Command failed: {command}\nstderr: {stderr}")]
    CommandFailed { command: String, stderr: String },

    #[error("Permission denied: must run as root")]
    PermissionDenied,

    #[error("{0}")]
    Other(String),
}
