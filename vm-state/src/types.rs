//! Core types for vm-state management

use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

/// A slot represents a fixed network identity (slot1 = 10.1.0.2, etc.)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Slot {
    Slot1,
    Slot2,
    Slot3,
    Slot4,
    Slot5,
}

impl Slot {
    /// All available slots
    pub const ALL: [Slot; 5] = [Slot::Slot1, Slot::Slot2, Slot::Slot3, Slot::Slot4, Slot::Slot5];

    /// Get the slot's IP address
    pub fn ip(&self) -> &'static str {
        match self {
            Slot::Slot1 => "10.1.0.2",
            Slot::Slot2 => "10.2.0.2",
            Slot::Slot3 => "10.3.0.2",
            Slot::Slot4 => "10.4.0.2",
            Slot::Slot5 => "10.5.0.2",
        }
    }

    /// Get the systemd service name
    pub fn service_name(&self) -> String {
        format!("microvm@{}.service", self.as_str())
    }

    /// Get the slot name as a string
    pub fn as_str(&self) -> &'static str {
        match self {
            Slot::Slot1 => "slot1",
            Slot::Slot2 => "slot2",
            Slot::Slot3 => "slot3",
            Slot::Slot4 => "slot4",
            Slot::Slot5 => "slot5",
        }
    }
}

impl fmt::Display for Slot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl FromStr for Slot {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "slot1" => Ok(Slot::Slot1),
            "slot2" => Ok(Slot::Slot2),
            "slot3" => Ok(Slot::Slot3),
            "slot4" => Ok(Slot::Slot4),
            "slot5" => Ok(Slot::Slot5),
            _ => Err(format!(
                "Invalid slot '{}'. Must be slot1, slot2, slot3, slot4, or slot5",
                s
            )),
        }
    }
}

/// A state name (portable data container)
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct State(String);

impl State {
    /// Create a new state from a name
    pub fn new(name: impl Into<String>) -> Result<Self, String> {
        let name = name.into();
        if name.is_empty() {
            return Err("State name cannot be empty".to_string());
        }
        if name.contains('/') || name.contains('@') {
            return Err("State name cannot contain '/' or '@'".to_string());
        }
        Ok(State(name))
    }

    /// Get the state name
    pub fn name(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for State {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl FromStr for State {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        State::new(s)
    }
}

/// A snapshot name
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Snapshot(String);

impl Snapshot {
    /// Create a new snapshot from a name
    pub fn new(name: impl Into<String>) -> Result<Self, String> {
        let name = name.into();
        if name.is_empty() {
            return Err("Snapshot name cannot be empty".to_string());
        }
        if name.contains('/') || name.contains('@') {
            return Err("Snapshot name cannot contain '/' or '@'".to_string());
        }
        Ok(Snapshot(name))
    }

    /// Get the snapshot name
    pub fn name(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Snapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl FromStr for Snapshot {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Snapshot::new(s)
    }
}

/// Information about a slot
#[derive(Debug, Clone)]
pub struct SlotInfo {
    pub slot: Slot,
    pub assigned_state: State,
    pub running: bool,
}

/// Information about a state
#[derive(Debug, Clone)]
pub struct StateInfo {
    pub state: State,
    pub used_bytes: u64,
    pub available_bytes: u64,
    pub zfs_dataset: String,
}

/// Information about a snapshot
#[derive(Debug, Clone)]
pub struct SnapshotInfo {
    pub state: State,
    pub snapshot: Snapshot,
    pub full_name: String,
    pub used_bytes: u64,
}
