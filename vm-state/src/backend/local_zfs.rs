//! Local ZFS backend implementation

use crate::error::{Error, Result};
use crate::types::{Slot, SlotInfo, Snapshot, SnapshotInfo, State, StateInfo};
use crate::VmStateBackend;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Configuration for the local ZFS backend
#[derive(Debug, Clone)]
pub struct LocalZfsConfig {
    /// Path to the states directory (e.g., /var/lib/microvms/states)
    pub states_dir: PathBuf,
    /// Path to the microvms directory (e.g., /var/lib/microvms)
    pub microvms_dir: PathBuf,
    /// Path to the assignments file (e.g., /etc/vm-state-assignments.json)
    pub assignments_file: PathBuf,
    /// ZFS pool name (e.g., microvms)
    pub zfs_pool: String,
    /// ZFS dataset path under the pool (e.g., storage/states)
    pub zfs_dataset: String,
}

impl Default for LocalZfsConfig {
    fn default() -> Self {
        Self {
            states_dir: PathBuf::from("/var/lib/microvms/states"),
            microvms_dir: PathBuf::from("/var/lib/microvms"),
            assignments_file: PathBuf::from("/etc/vm-state-assignments.json"),
            zfs_pool: "microvms".to_string(),
            zfs_dataset: "storage/states".to_string(),
        }
    }
}

/// Slot-to-state assignments stored in JSON
#[derive(Debug, Default, Serialize, Deserialize)]
struct Assignments(HashMap<String, String>);

/// Local ZFS backend implementation
///
/// This implementation manages VM states using ZFS datasets on the local system.
/// It replicates the functionality of the vm-state.sh shell script.
pub struct LocalZfsBackend {
    config: LocalZfsConfig,
}

impl LocalZfsBackend {
    /// Create a new LocalZfsBackend with default configuration
    pub fn new() -> Result<Self> {
        Self::with_config(LocalZfsConfig::default())
    }

    /// Create a new LocalZfsBackend with custom configuration
    pub fn with_config(config: LocalZfsConfig) -> Result<Self> {
        // Check if running as root
        if !nix::unistd::geteuid().is_root() {
            return Err(Error::PermissionDenied);
        }
        Ok(Self { config })
    }

    /// Get the full ZFS dataset path for a state
    fn dataset_path(&self, state: &State) -> String {
        format!(
            "{}/{}/{}",
            self.config.zfs_pool,
            self.config.zfs_dataset,
            state.name()
        )
    }

    /// Get the base ZFS dataset path (parent of all states)
    fn base_dataset(&self) -> String {
        format!("{}/{}", self.config.zfs_pool, self.config.zfs_dataset)
    }

    /// Get the state directory path
    fn state_dir(&self, state: &State) -> PathBuf {
        self.config.states_dir.join(state.name())
    }

    /// Get the slot directory path
    fn slot_dir(&self, slot: Slot) -> PathBuf {
        self.config.microvms_dir.join(slot.as_str())
    }

    /// Get the data.img path for a slot
    fn slot_data_img(&self, slot: Slot) -> PathBuf {
        self.slot_dir(slot).join("data.img")
    }

    /// Get the data.img path for a state
    fn state_data_img(&self, state: &State) -> PathBuf {
        self.state_dir(state).join("data.img")
    }

    /// Load assignments from file
    fn load_assignments(&self) -> Result<Assignments> {
        if self.config.assignments_file.exists() {
            let content = fs::read_to_string(&self.config.assignments_file)?;
            Ok(serde_json::from_str(&content)?)
        } else {
            Ok(Assignments::default())
        }
    }

    /// Save assignments to file
    fn save_assignments(&self, assignments: &Assignments) -> Result<()> {
        let content = serde_json::to_string_pretty(assignments)?;
        fs::write(&self.config.assignments_file, content)?;
        Ok(())
    }

    /// Run a command and return stdout
    fn run_command(&self, program: &str, args: &[&str]) -> Result<String> {
        let output = Command::new(program).args(args).output()?;

        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).to_string())
        } else {
            Err(Error::CommandFailed {
                command: format!("{} {}", program, args.join(" ")),
                stderr: String::from_utf8_lossy(&output.stderr).to_string(),
            })
        }
    }

    /// Run a command, returning Ok(true) if it succeeds, Ok(false) if it fails
    fn run_command_check(&self, program: &str, args: &[&str]) -> Result<bool> {
        let status = Command::new(program).args(args).status()?;
        Ok(status.success())
    }

    /// Run systemctl command
    fn systemctl(&self, action: &str, slot: Slot) -> Result<()> {
        self.run_command("systemctl", &[action, &slot.service_name()])?;
        Ok(())
    }

    /// Set ownership to microvm:kvm
    fn set_microvm_ownership(&self, path: &Path) -> Result<()> {
        self.run_command("chown", &["microvm:kvm", &path.to_string_lossy()])?;
        self.run_command("chmod", &["755", &path.to_string_lossy()])?;
        Ok(())
    }

    /// Parse ZFS list output for datasets
    fn parse_zfs_list(&self, output: &str) -> Vec<(String, u64, u64)> {
        output
            .lines()
            .filter_map(|line| {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 3 {
                    let name = parts[0].to_string();
                    let used = self.parse_size(parts[1]).unwrap_or(0);
                    let avail = self.parse_size(parts[2]).unwrap_or(0);
                    Some((name, used, avail))
                } else {
                    None
                }
            })
            .collect()
    }

    /// Parse size strings like "1.5G", "500M", "10K"
    fn parse_size(&self, s: &str) -> Option<u64> {
        let s = s.trim();
        if s == "-" || s.is_empty() {
            return Some(0);
        }

        let (num_str, multiplier) = if let Some(n) = s.strip_suffix('T') {
            (n, 1024u64 * 1024 * 1024 * 1024)
        } else if let Some(n) = s.strip_suffix('G') {
            (n, 1024u64 * 1024 * 1024)
        } else if let Some(n) = s.strip_suffix('M') {
            (n, 1024u64 * 1024)
        } else if let Some(n) = s.strip_suffix('K') {
            (n, 1024u64)
        } else if let Some(n) = s.strip_suffix('B') {
            (n, 1)
        } else {
            (s, 1)
        };

        num_str.parse::<f64>().ok().map(|n| (n * multiplier as f64) as u64)
    }
}

impl Default for LocalZfsBackend {
    fn default() -> Self {
        Self::new().expect("Failed to create LocalZfsBackend")
    }
}

impl VmStateBackend for LocalZfsBackend {
    fn list_slots(&self) -> Result<Vec<SlotInfo>> {
        let mut slots = Vec::new();
        let assignments = self.load_assignments()?;

        for slot in Slot::ALL {
            let assigned_state = assignments
                .0
                .get(slot.as_str())
                .cloned()
                .unwrap_or_else(|| slot.as_str().to_string());

            let state = State::new(&assigned_state).map_err(|e| Error::Other(e))?;
            let running = self.is_slot_running(slot)?;

            slots.push(SlotInfo {
                slot,
                assigned_state: state,
                running,
            });
        }

        Ok(slots)
    }

    fn list_states(&self) -> Result<Vec<StateInfo>> {
        let base = self.base_dataset();
        let output = self.run_command("zfs", &["list", "-H", "-o", "name,used,avail", "-r", &base])?;

        let mut states = Vec::new();
        for (name, used, avail) in self.parse_zfs_list(&output) {
            // Skip the base dataset itself
            if name == base {
                continue;
            }
            // Skip snapshots
            if name.contains('@') {
                continue;
            }

            let state_name = name.rsplit('/').next().unwrap_or(&name);
            if let Ok(state) = State::new(state_name) {
                states.push(StateInfo {
                    state,
                    used_bytes: used,
                    available_bytes: avail,
                    zfs_dataset: name,
                });
            }
        }

        Ok(states)
    }

    fn list_snapshots(&self) -> Result<Vec<SnapshotInfo>> {
        let base = self.base_dataset();
        let output = self.run_command(
            "zfs",
            &["list", "-H", "-t", "snapshot", "-o", "name,used", "-r", &base],
        )?;

        let mut snapshots = Vec::new();
        for line in output.lines() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 2 {
                let full_name = parts[0];
                let used = self.parse_size(parts[1]).unwrap_or(0);

                // Parse state@snapshot format
                if let Some((dataset, snap_name)) = full_name.rsplit_once('@') {
                    let state_name = dataset.rsplit('/').next().unwrap_or(dataset);
                    if let (Ok(state), Ok(snapshot)) =
                        (State::new(state_name), Snapshot::new(snap_name))
                    {
                        snapshots.push(SnapshotInfo {
                            state,
                            snapshot,
                            full_name: full_name.to_string(),
                            used_bytes: used,
                        });
                    }
                }
            }
        }

        Ok(snapshots)
    }

    fn get_slot_state(&self, slot: Slot) -> Result<State> {
        let assignments = self.load_assignments()?;
        let state_name = assignments
            .0
            .get(slot.as_str())
            .cloned()
            .unwrap_or_else(|| slot.as_str().to_string());

        State::new(&state_name).map_err(|e| Error::Other(e))
    }

    fn is_slot_running(&self, slot: Slot) -> Result<bool> {
        self.run_command_check("systemctl", &["is-active", "--quiet", &slot.service_name()])
    }

    fn state_exists(&self, state: &State) -> Result<bool> {
        let dataset = self.dataset_path(state);
        self.run_command_check("zfs", &["list", "-H", &dataset])
    }

    fn create_state(&self, state: &State) -> Result<()> {
        if self.state_exists(state)? {
            return Err(Error::StateAlreadyExists(state.clone()));
        }

        let dataset = self.dataset_path(state);
        let mountpoint = self.state_dir(state);

        // Create ZFS dataset
        self.run_command(
            "zfs",
            &[
                "create",
                "-o",
                &format!("mountpoint={}", mountpoint.display()),
                &dataset,
            ],
        )?;

        // Set permissions
        self.set_microvm_ownership(&mountpoint)?;

        Ok(())
    }

    fn delete_state(&self, state: &State) -> Result<()> {
        if !self.state_exists(state)? {
            return Err(Error::StateNotFound(state.clone()));
        }

        // Check if state is in use
        let assignments = self.load_assignments()?;
        for slot in Slot::ALL {
            let assigned = assignments
                .0
                .get(slot.as_str())
                .cloned()
                .unwrap_or_else(|| slot.as_str().to_string());
            if assigned == state.name() {
                return Err(Error::StateInUse {
                    state: state.clone(),
                    slot,
                });
            }
        }

        let dataset = self.dataset_path(state);

        // Delete all snapshots first
        let snapshots = self.list_snapshots()?;
        for snap in snapshots {
            if snap.state == *state {
                self.run_command("zfs", &["destroy", &snap.full_name])?;
            }
        }

        // Delete the dataset
        self.run_command("zfs", &["destroy", &dataset])?;

        Ok(())
    }

    fn clone_state(&self, source: &State, destination: &State) -> Result<()> {
        if !self.state_exists(source)? {
            return Err(Error::StateNotFound(source.clone()));
        }
        if self.state_exists(destination)? {
            return Err(Error::StateAlreadyExists(destination.clone()));
        }

        let src_dataset = self.dataset_path(source);
        let dst_dataset = self.dataset_path(destination);
        let dst_mountpoint = self.state_dir(destination);
        let clone_snap = format!("{}@clone-for-{}", src_dataset, destination.name());

        // Create a snapshot for the clone
        self.run_command("zfs", &["snapshot", &clone_snap])?;

        // Clone from snapshot
        self.run_command(
            "zfs",
            &[
                "clone",
                "-o",
                &format!("mountpoint={}", dst_mountpoint.display()),
                &clone_snap,
                &dst_dataset,
            ],
        )?;

        // Promote the clone to a full dataset
        self.run_command("zfs", &["promote", &dst_dataset])?;

        // Set permissions
        self.set_microvm_ownership(&dst_mountpoint)?;

        Ok(())
    }

    fn snapshot(&self, slot: Slot, snapshot_name: &Snapshot) -> Result<()> {
        let state = self.get_slot_state(slot)?;
        let dataset = self.dataset_path(&state);

        if !self.state_exists(&state)? {
            return Err(Error::StateNotFound(state));
        }

        let snapshot_full = format!("{}@{}", dataset, snapshot_name.name());
        self.run_command("zfs", &["snapshot", &snapshot_full])?;

        Ok(())
    }

    fn restore_snapshot(&self, snapshot_name: &Snapshot, new_state: &State) -> Result<()> {
        if self.state_exists(new_state)? {
            return Err(Error::StateAlreadyExists(new_state.clone()));
        }

        // Find the snapshot
        let snapshots = self.list_snapshots()?;
        let snap_info = snapshots
            .iter()
            .find(|s| s.snapshot == *snapshot_name)
            .ok_or_else(|| Error::SnapshotNotFound(snapshot_name.name().to_string()))?;

        let dst_dataset = self.dataset_path(new_state);
        let dst_mountpoint = self.state_dir(new_state);

        // Clone from snapshot
        self.run_command(
            "zfs",
            &[
                "clone",
                "-o",
                &format!("mountpoint={}", dst_mountpoint.display()),
                &snap_info.full_name,
                &dst_dataset,
            ],
        )?;

        // Promote to full dataset
        self.run_command("zfs", &["promote", &dst_dataset])?;

        // Set permissions
        self.set_microvm_ownership(&dst_mountpoint)?;

        Ok(())
    }

    fn assign(&self, slot: Slot, state: &State) -> Result<()> {
        // Create state if it doesn't exist
        if !self.state_exists(state)? {
            self.create_state(state)?;
        }

        // Update assignment
        let mut assignments = self.load_assignments()?;
        assignments
            .0
            .insert(slot.as_str().to_string(), state.name().to_string());
        self.save_assignments(&assignments)?;

        // Create symlink from slot's data.img to state's data.img
        let slot_dir = self.slot_dir(slot);
        let slot_data = self.slot_data_img(slot);
        let state_data = self.state_data_img(state);

        // Ensure slot directory exists
        fs::create_dir_all(&slot_dir)?;
        self.run_command("chown", &["microvm:kvm", &slot_dir.to_string_lossy()])?;

        // Handle existing data.img
        if slot_data.is_symlink() {
            fs::remove_file(&slot_data)?;
        } else if slot_data.exists() {
            let backup = slot_dir.join("data.img.backup");
            fs::rename(&slot_data, &backup)?;
        }

        // Create symlink
        symlink(&state_data, &slot_data)?;

        Ok(())
    }

    fn migrate(&self, state: &State, slot: Slot) -> Result<()> {
        // Stop the slot if running
        if self.is_slot_running(slot)? {
            self.stop_slot(slot)?;
            std::thread::sleep(std::time::Duration::from_secs(2));
        }

        // Assign the state
        self.assign(slot, state)?;

        // Start the slot
        self.start_slot(slot)?;

        Ok(())
    }

    fn start_slot(&self, slot: Slot) -> Result<()> {
        self.systemctl("start", slot)
    }

    fn stop_slot(&self, slot: Slot) -> Result<()> {
        self.systemctl("stop", slot)
    }

    fn restart_slot(&self, slot: Slot) -> Result<()> {
        self.systemctl("restart", slot)
    }
}
