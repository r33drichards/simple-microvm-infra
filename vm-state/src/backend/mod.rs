//! Backend trait and implementations for vm-state

mod local_zfs;

pub use local_zfs::LocalZfsBackend;

use crate::error::Result;
use crate::types::{Slot, SlotInfo, Snapshot, SnapshotInfo, State, StateInfo};

/// Trait defining the vm-state management API
///
/// This trait abstracts over the storage backend, allowing for different
/// implementations (local ZFS, remote ZFS, mock for testing, etc.)
pub trait VmStateBackend {
    // === Query Operations ===

    /// List all slots with their assigned states and running status
    fn list_slots(&self) -> Result<Vec<SlotInfo>>;

    /// List all available states
    fn list_states(&self) -> Result<Vec<StateInfo>>;

    /// List all snapshots
    fn list_snapshots(&self) -> Result<Vec<SnapshotInfo>>;

    /// Get the state assigned to a slot
    fn get_slot_state(&self, slot: Slot) -> Result<State>;

    /// Check if a slot is running
    fn is_slot_running(&self, slot: Slot) -> Result<bool>;

    /// Check if a state exists
    fn state_exists(&self, state: &State) -> Result<bool>;

    // === State Management ===

    /// Create a new empty state
    fn create_state(&self, state: &State) -> Result<()>;

    /// Delete a state (must not be assigned to any slot)
    fn delete_state(&self, state: &State) -> Result<()>;

    /// Clone a state to a new name
    fn clone_state(&self, source: &State, destination: &State) -> Result<()>;

    // === Snapshot Operations ===

    /// Create a snapshot of a slot's current state
    fn snapshot(&self, slot: Slot, snapshot_name: &Snapshot) -> Result<()>;

    /// Restore a snapshot to a new state
    fn restore_snapshot(&self, snapshot_name: &Snapshot, new_state: &State) -> Result<()>;

    // === Slot Assignment ===

    /// Assign a state to a slot (does not restart the slot)
    fn assign(&self, slot: Slot, state: &State) -> Result<()>;

    /// Migrate a state to a slot (stops slot, assigns, starts slot)
    fn migrate(&self, state: &State, slot: Slot) -> Result<()>;

    // === Slot Control ===

    /// Start a slot
    fn start_slot(&self, slot: Slot) -> Result<()>;

    /// Stop a slot
    fn stop_slot(&self, slot: Slot) -> Result<()>;

    /// Restart a slot
    fn restart_slot(&self, slot: Slot) -> Result<()>;
}
