//! vm-state CLI - Manage portable MicroVM states

use clap::{Parser, Subcommand};
use colored::Colorize;
use std::process::ExitCode;
use vm_state::{
    backend::LocalZfsBackend, Error, Result, Slot, Snapshot, State, VmStateBackend,
};

#[derive(Parser)]
#[command(name = "vm-state")]
#[command(about = "Manage portable MicroVM states", long_about = None)]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// List all states and slot assignments
    List,

    /// Create a new empty state
    Create {
        /// Name for the new state
        name: String,
    },

    /// Snapshot current slot's state
    Snapshot {
        /// Slot to snapshot (slot1-slot5)
        slot: String,
        /// Name for the snapshot
        name: String,
    },

    /// Assign a state to a slot
    Assign {
        /// Slot to assign to (slot1-slot5)
        slot: String,
        /// State to assign
        state: String,
    },

    /// Clone a state to a new name
    Clone {
        /// Source state to clone
        source: String,
        /// Destination state name
        destination: String,
    },

    /// Delete a state (must not be in use)
    Delete {
        /// State to delete
        name: String,
    },

    /// Stop slot, assign state, start slot
    Migrate {
        /// State to migrate
        state: String,
        /// Slot to migrate to (slot1-slot5)
        slot: String,
    },

    /// Restore a snapshot to a new state
    Restore {
        /// Snapshot name to restore
        snapshot: String,
        /// New state name
        state: String,
    },

    /// Start a slot
    Start {
        /// Slot to start (slot1-slot5)
        slot: String,
    },

    /// Stop a slot
    Stop {
        /// Slot to stop (slot1-slot5)
        slot: String,
    },

    /// Restart a slot
    Restart {
        /// Slot to restart (slot1-slot5)
        slot: String,
    },
}

fn info(msg: &str) {
    println!("{} {}", "[INFO]".blue(), msg);
}

fn success(msg: &str) {
    println!("{} {}", "[OK]".green(), msg);
}

fn warn(msg: &str) {
    println!("{} {}", "[WARN]".yellow(), msg);
}

fn error(msg: &str) {
    eprintln!("{} {}", "[ERROR]".red(), msg);
}

fn format_size(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;
    const TB: u64 = GB * 1024;

    if bytes >= TB {
        format!("{:.1}T", bytes as f64 / TB as f64)
    } else if bytes >= GB {
        format!("{:.1}G", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.1}M", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.1}K", bytes as f64 / KB as f64)
    } else {
        format!("{}B", bytes)
    }
}

fn cmd_list(backend: &impl VmStateBackend) -> Result<()> {
    info("States and assignments:");
    println!();
    println!(
        "{:<15} {:<15} {:<10} {}",
        "SLOT", "STATE", "RUNNING", "ZFS DATASET"
    );
    println!(
        "{:<15} {:<15} {:<10} {}",
        "----", "-----", "-------", "-----------"
    );

    for slot_info in backend.list_slots()? {
        let running = if slot_info.running { "yes" } else { "no" };
        let dataset = format!("microvms/storage/states/{}", slot_info.assigned_state);
        println!(
            "{:<15} {:<15} {:<10} {}",
            slot_info.slot, slot_info.assigned_state, running, dataset
        );
    }

    println!();
    info("Available states (ZFS datasets):");
    let states = backend.list_states()?;
    if states.is_empty() {
        println!("  (no states created yet)");
    } else {
        for state_info in states {
            println!(
                "  {:<20} used: {:<8} avail: {}",
                state_info.state,
                format_size(state_info.used_bytes),
                format_size(state_info.available_bytes)
            );
        }
    }

    println!();
    info("Snapshots:");
    let snapshots = backend.list_snapshots()?;
    if snapshots.is_empty() {
        println!("  (no snapshots)");
    } else {
        for snap in snapshots.iter().take(20) {
            println!("  {}", snap.full_name);
        }
        if snapshots.len() > 20 {
            println!("  ... and {} more", snapshots.len() - 20);
        }
    }

    Ok(())
}

fn cmd_create(backend: &impl VmStateBackend, name: &str) -> Result<()> {
    let state = State::new(name).map_err(|e| Error::Other(e))?;

    info(&format!("Creating state '{}'...", state));
    backend.create_state(&state)?;
    success(&format!(
        "State '{}' created at /var/lib/microvms/states/{}",
        state, state
    ));
    info(&format!("Assign it to a slot with: vm-state assign <slot> {}", state));

    Ok(())
}

fn cmd_snapshot(backend: &impl VmStateBackend, slot_str: &str, name: &str) -> Result<()> {
    let slot: Slot = slot_str.parse().map_err(|e| Error::Other(e))?;
    let snapshot = Snapshot::new(name).map_err(|e| Error::Other(e))?;
    let state = backend.get_slot_state(slot)?;

    if backend.is_slot_running(slot)? {
        warn(&format!(
            "{} is running - snapshot will be crash-consistent",
            slot
        ));
        warn(&format!(
            "For a clean snapshot, stop the slot first: systemctl stop microvm@{}",
            slot
        ));
    }

    info(&format!(
        "Creating snapshot of state '{}' (from {})...",
        state, slot
    ));
    backend.snapshot(slot, &snapshot)?;
    success(&format!(
        "Snapshot created: microvms/storage/states/{}@{}",
        state, snapshot
    ));

    Ok(())
}

fn cmd_assign(backend: &impl VmStateBackend, slot_str: &str, state_str: &str) -> Result<()> {
    let slot: Slot = slot_str.parse().map_err(|e| Error::Other(e))?;
    let state = State::new(state_str).map_err(|e| Error::Other(e))?;

    let was_running = backend.is_slot_running(slot)?;
    if was_running {
        warn(&format!(
            "{} is currently running. Assignment will take effect after restart.",
            slot
        ));
    }

    if !backend.state_exists(&state)? {
        warn(&format!("State '{}' doesn't exist yet. Creating it...", state));
    }

    backend.assign(slot, &state)?;

    info(&format!(
        "Created symlink: /var/lib/microvms/{}/data.img -> /var/lib/microvms/states/{}/data.img",
        slot, state
    ));
    success(&format!("Assigned state '{}' to {}", state, slot));

    if was_running {
        info(&format!(
            "Restart the slot to use the new state: systemctl restart microvm@{}",
            slot
        ));
    } else {
        info(&format!("Start the slot with: systemctl start microvm@{}", slot));
    }

    Ok(())
}

fn cmd_clone(backend: &impl VmStateBackend, source: &str, destination: &str) -> Result<()> {
    let src = State::new(source).map_err(|e| Error::Other(e))?;
    let dst = State::new(destination).map_err(|e| Error::Other(e))?;

    info(&format!("Cloning state '{}' to '{}'...", src, dst));
    backend.clone_state(&src, &dst)?;
    success(&format!("State '{}' cloned to '{}'", src, dst));
    info(&format!("Assign it to a slot with: vm-state assign <slot> {}", dst));

    Ok(())
}

fn cmd_delete(backend: &impl VmStateBackend, name: &str) -> Result<()> {
    let state = State::new(name).map_err(|e| Error::Other(e))?;

    warn(&format!(
        "This will permanently delete state '{}' and all its data!",
        state
    ));

    // Read confirmation from stdin
    use std::io::{self, Write};
    print!("Type 'DELETE' to confirm: ");
    io::stdout().flush()?;

    let mut input = String::new();
    io::stdin().read_line(&mut input)?;

    if input.trim() != "DELETE" {
        return Err(Error::Other("Aborted".to_string()));
    }

    info(&format!("Deleting state '{}'...", state));
    backend.delete_state(&state)?;
    success(&format!("State '{}' deleted", state));

    Ok(())
}

fn cmd_migrate(backend: &impl VmStateBackend, state_str: &str, slot_str: &str) -> Result<()> {
    let slot: Slot = slot_str.parse().map_err(|e| Error::Other(e))?;
    let state = State::new(state_str).map_err(|e| Error::Other(e))?;

    info(&format!("Migrating state '{}' to {}...", state, slot));

    if backend.is_slot_running(slot)? {
        info(&format!("Stopping {}...", slot));
    }

    backend.migrate(&state, slot)?;
    success(&format!(
        "Migration complete. {} is now running state '{}'",
        slot, state
    ));

    Ok(())
}

fn cmd_restore(backend: &impl VmStateBackend, snapshot_str: &str, state_str: &str) -> Result<()> {
    let snapshot = Snapshot::new(snapshot_str).map_err(|e| Error::Other(e))?;
    let state = State::new(state_str).map_err(|e| Error::Other(e))?;

    info(&format!(
        "Restoring snapshot '{}' to state '{}'...",
        snapshot, state
    ));
    backend.restore_snapshot(&snapshot, &state)?;
    success(&format!("Snapshot restored to state '{}'", state));
    info(&format!("Assign it to a slot with: vm-state assign <slot> {}", state));

    Ok(())
}

fn cmd_start(backend: &impl VmStateBackend, slot_str: &str) -> Result<()> {
    let slot: Slot = slot_str.parse().map_err(|e| Error::Other(e))?;

    info(&format!("Starting {}...", slot));
    backend.start_slot(slot)?;
    success(&format!("{} started", slot));

    Ok(())
}

fn cmd_stop(backend: &impl VmStateBackend, slot_str: &str) -> Result<()> {
    let slot: Slot = slot_str.parse().map_err(|e| Error::Other(e))?;

    info(&format!("Stopping {}...", slot));
    backend.stop_slot(slot)?;
    success(&format!("{} stopped", slot));

    Ok(())
}

fn cmd_restart(backend: &impl VmStateBackend, slot_str: &str) -> Result<()> {
    let slot: Slot = slot_str.parse().map_err(|e| Error::Other(e))?;

    info(&format!("Restarting {}...", slot));
    backend.restart_slot(slot)?;
    success(&format!("{} restarted", slot));

    Ok(())
}

fn run() -> Result<()> {
    let cli = Cli::parse();

    let backend = LocalZfsBackend::new()?;

    match cli.command {
        None | Some(Commands::List) => cmd_list(&backend),
        Some(Commands::Create { name }) => cmd_create(&backend, &name),
        Some(Commands::Snapshot { slot, name }) => cmd_snapshot(&backend, &slot, &name),
        Some(Commands::Assign { slot, state }) => cmd_assign(&backend, &slot, &state),
        Some(Commands::Clone { source, destination }) => cmd_clone(&backend, &source, &destination),
        Some(Commands::Delete { name }) => cmd_delete(&backend, &name),
        Some(Commands::Migrate { state, slot }) => cmd_migrate(&backend, &state, &slot),
        Some(Commands::Restore { snapshot, state }) => cmd_restore(&backend, &snapshot, &state),
        Some(Commands::Start { slot }) => cmd_start(&backend, &slot),
        Some(Commands::Stop { slot }) => cmd_stop(&backend, &slot),
        Some(Commands::Restart { slot }) => cmd_restart(&backend, &slot),
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            error(&e.to_string());
            ExitCode::FAILURE
        }
    }
}
