#include "cli/cli.hpp"
#include <iostream>
#include <iomanip>
#include <unistd.h>
#include <cstdlib>

namespace vmstate {

// ANSI color codes
namespace colors {
    const char* RED = "\033[0;31m";
    const char* GREEN = "\033[0;32m";
    const char* YELLOW = "\033[1;33m";
    const char* BLUE = "\033[0;34m";
    const char* RESET = "\033[0m";
}

CLI::CLI(std::unique_ptr<VMProvider> vm_provider,
         std::unique_ptr<StateProvider> state_provider)
    : vm_provider_(std::move(vm_provider)),
      state_provider_(std::move(state_provider)) {
    // Disable colors if not a TTY
    use_colors_ = isatty(STDOUT_FILENO) != 0;
}

void CLI::info(const std::string& msg) const {
    if (use_colors_) {
        std::cout << colors::BLUE << "[INFO]" << colors::RESET << " " << msg << std::endl;
    } else {
        std::cout << "[INFO] " << msg << std::endl;
    }
}

void CLI::success(const std::string& msg) const {
    if (use_colors_) {
        std::cout << colors::GREEN << "[OK]" << colors::RESET << " " << msg << std::endl;
    } else {
        std::cout << "[OK] " << msg << std::endl;
    }
}

void CLI::warn(const std::string& msg) const {
    if (use_colors_) {
        std::cout << colors::YELLOW << "[WARN]" << colors::RESET << " " << msg << std::endl;
    } else {
        std::cout << "[WARN] " << msg << std::endl;
    }
}

void CLI::error(const std::string& msg) const {
    if (use_colors_) {
        std::cerr << colors::RED << "[ERROR]" << colors::RESET << " " << msg << std::endl;
    } else {
        std::cerr << "[ERROR] " << msg << std::endl;
    }
}

bool CLI::check_root() const {
    if (geteuid() != 0) {
        error("This command must be run as root");
        return false;
    }
    return true;
}

std::string CLI::status_string(VMStatus status) const {
    switch (status) {
        case VMStatus::Running: return "yes";
        case VMStatus::Stopped: return "no";
        case VMStatus::Failed: return "failed";
        default: return "unknown";
    }
}

int CLI::run(int argc, char* argv[]) {
    if (argc < 2) {
        return cmd_list();
    }

    std::string cmd = argv[1];
    std::vector<std::string> args;
    for (int i = 2; i < argc; i++) {
        args.push_back(argv[i]);
    }

    if (cmd == "list") {
        return cmd_list();
    } else if (cmd == "create") {
        return cmd_create(args);
    } else if (cmd == "snapshot") {
        return cmd_snapshot(args);
    } else if (cmd == "assign") {
        return cmd_assign(args);
    } else if (cmd == "clone") {
        return cmd_clone(args);
    } else if (cmd == "delete") {
        return cmd_delete(args);
    } else if (cmd == "migrate") {
        return cmd_migrate(args);
    } else if (cmd == "restore") {
        return cmd_restore(args);
    } else if (cmd == "help" || cmd == "--help" || cmd == "-h") {
        return cmd_help();
    } else {
        error("Unknown command: " + cmd + ". Use 'vm-state help' for usage.");
        return 1;
    }
}

int CLI::cmd_list() {
    if (!check_root()) return 1;

    info("States and assignments:");
    std::cout << std::endl;

    // Header
    std::cout << std::left
              << std::setw(15) << "SLOT"
              << std::setw(15) << "STATE"
              << std::setw(10) << "RUNNING"
              << "ZFS DATASET" << std::endl;
    std::cout << std::left
              << std::setw(15) << "----"
              << std::setw(15) << "-----"
              << std::setw(10) << "-------"
              << "-----------" << std::endl;

    // List slots and their assignments
    auto assignments = state_provider_->list_assignments();
    for (const auto& a : assignments) {
        bool running = vm_provider_->is_running(a.slot_name);
        auto state_info = state_provider_->get_state_info(a.state_name);

        std::cout << std::left
                  << std::setw(15) << a.slot_name
                  << std::setw(15) << a.state_name
                  << std::setw(10) << (running ? "yes" : "no")
                  << (state_info ? state_info->dataset : "(not found)")
                  << std::endl;
    }

    std::cout << std::endl;
    info("Available states (ZFS datasets):");

    auto states = state_provider_->list_states();
    if (states.empty()) {
        std::cout << "  (no states created yet)" << std::endl;
    } else {
        for (const auto& state : states) {
            std::cout << "  " << std::left << std::setw(20) << state.name;

            // Format sizes
            auto format_size = [](uint64_t bytes) -> std::string {
                const char* suffixes[] = {"B", "K", "M", "G", "T"};
                int idx = 0;
                double size = static_cast<double>(bytes);
                while (size >= 1024 && idx < 4) {
                    size /= 1024;
                    idx++;
                }
                char buf[32];
                snprintf(buf, sizeof(buf), "%.1f%s", size, suffixes[idx]);
                return std::string(buf);
            };

            std::cout << "used: " << std::left << std::setw(8) << format_size(state.used_bytes)
                      << "avail: " << format_size(state.available_bytes)
                      << std::endl;
        }
    }

    std::cout << std::endl;
    info("Snapshots:");

    auto snapshots = state_provider_->list_snapshots();
    if (snapshots.empty()) {
        std::cout << "  (no snapshots)" << std::endl;
    } else {
        int count = 0;
        for (const auto& snap : snapshots) {
            std::cout << "  " << snap.full_name << std::endl;
            if (++count >= 20) {
                std::cout << "  ... (truncated)" << std::endl;
                break;
            }
        }
    }

    return 0;
}

int CLI::cmd_create(const std::vector<std::string>& args) {
    if (!check_root()) return 1;

    if (args.empty()) {
        error("Usage: vm-state create <name>");
        return 1;
    }

    std::string name = args[0];
    info("Creating state '" + name + "'...");

    if (!state_provider_->create_state(name)) {
        error(state_provider_->get_last_error());
        return 1;
    }

    success("State '" + name + "' created at " + state_provider_->get_states_dir() + "/" + name);
    info("Assign it to a slot with: vm-state assign <slot> " + name);
    return 0;
}

int CLI::cmd_snapshot(const std::vector<std::string>& args) {
    if (!check_root()) return 1;

    if (args.size() < 2) {
        error("Usage: vm-state snapshot <slot> <snapshot-name>");
        return 1;
    }

    std::string slot = args[0];
    std::string snapshot_name = args[1];

    // Get state for this slot
    std::string state = state_provider_->get_slot_state(slot);

    info("Creating snapshot of state '" + state + "' (from " + slot + ")...");

    // Warn if slot is running
    if (vm_provider_->is_running(slot)) {
        warn(slot + " is running - snapshot will be crash-consistent");
        warn("For a clean snapshot, stop the slot first: systemctl stop microvm@" + slot);
    }

    if (!state_provider_->create_snapshot(state, snapshot_name)) {
        error(state_provider_->get_last_error());
        return 1;
    }

    auto info_opt = state_provider_->get_state_info(state);
    std::string dataset = info_opt ? info_opt->dataset : state;
    success("Snapshot created: " + dataset + "@" + snapshot_name);
    return 0;
}

int CLI::cmd_assign(const std::vector<std::string>& args) {
    if (!check_root()) return 1;

    if (args.size() < 2) {
        error("Usage: vm-state assign <slot> <state>");
        return 1;
    }

    std::string slot = args[0];
    std::string state = args[1];

    // Validate slot
    if (!vm_provider_->is_valid_slot(slot)) {
        error("Invalid slot name '" + slot + "'. Must be slot1-slot5.");
        return 1;
    }

    bool running = vm_provider_->is_running(slot);
    if (running) {
        warn(slot + " is currently running. Assignment will take effect after restart.");
    }

    // Create state if needed
    if (!state_provider_->state_exists(state)) {
        warn("State '" + state + "' doesn't exist yet. Creating it...");
    }

    if (!state_provider_->assign_state(slot, state)) {
        error(state_provider_->get_last_error());
        return 1;
    }

    success("Assigned state '" + state + "' to " + slot);

    if (running) {
        info("Restart the slot to use the new state: systemctl restart microvm@" + slot);
    } else {
        info("Start the slot with: systemctl start microvm@" + slot);
    }

    return 0;
}

int CLI::cmd_clone(const std::vector<std::string>& args) {
    if (!check_root()) return 1;

    if (args.size() < 2) {
        error("Usage: vm-state clone <source-state> <destination-state>");
        return 1;
    }

    std::string src = args[0];
    std::string dst = args[1];

    info("Cloning state '" + src + "' to '" + dst + "'...");

    if (!state_provider_->clone_state(src, dst)) {
        error(state_provider_->get_last_error());
        return 1;
    }

    success("State '" + src + "' cloned to '" + dst + "'");
    info("Assign it to a slot with: vm-state assign <slot> " + dst);
    return 0;
}

int CLI::cmd_delete(const std::vector<std::string>& args) {
    if (!check_root()) return 1;

    if (args.empty()) {
        error("Usage: vm-state delete <name>");
        return 1;
    }

    std::string name = args[0];

    // Check if in use
    auto slot = state_provider_->is_state_in_use(name);
    if (slot) {
        error("State '" + name + "' is assigned to " + *slot +
              ". Reassign first with: vm-state assign " + *slot + " <other-state>");
        return 1;
    }

    warn("This will permanently delete state '" + name + "' and all its data!");
    std::cout << "Type 'DELETE' to confirm: ";
    std::cout.flush();

    std::string confirm;
    std::getline(std::cin, confirm);

    if (confirm != "DELETE") {
        error("Aborted");
        return 1;
    }

    info("Deleting state '" + name + "'...");

    if (!state_provider_->delete_state(name)) {
        error(state_provider_->get_last_error());
        return 1;
    }

    success("State '" + name + "' deleted");
    return 0;
}

int CLI::cmd_migrate(const std::vector<std::string>& args) {
    if (!check_root()) return 1;

    if (args.size() < 2) {
        error("Usage: vm-state migrate <state> <slot>");
        return 1;
    }

    std::string state = args[0];
    std::string slot = args[1];

    info("Migrating state '" + state + "' to " + slot + "...");

    // Stop slot if running
    if (vm_provider_->is_running(slot)) {
        info("Stopping " + slot + "...");
        if (!vm_provider_->stop(slot)) {
            error("Failed to stop " + slot + ": " + vm_provider_->get_last_error());
            return 1;
        }
        // Wait a moment for clean shutdown
        sleep(2);
    }

    // Assign state
    if (!state_provider_->assign_state(slot, state)) {
        error(state_provider_->get_last_error());
        return 1;
    }

    // Start slot
    info("Starting " + slot + " with state '" + state + "'...");
    if (!vm_provider_->start(slot)) {
        error("Failed to start " + slot + ": " + vm_provider_->get_last_error());
        return 1;
    }

    success("Migration complete. " + slot + " is now running state '" + state + "'");
    return 0;
}

int CLI::cmd_restore(const std::vector<std::string>& args) {
    if (!check_root()) return 1;

    if (args.size() < 2) {
        error("Usage: vm-state restore <snapshot-name> <new-state-name>");
        return 1;
    }

    std::string snapshot = args[0];
    std::string new_state = args[1];

    info("Restoring snapshot '" + snapshot + "' to state '" + new_state + "'...");

    if (!state_provider_->restore_snapshot(snapshot, new_state)) {
        error(state_provider_->get_last_error());
        return 1;
    }

    success("Snapshot restored to state '" + new_state + "'");
    info("Assign it to a slot with: vm-state assign <slot> " + new_state);
    return 0;
}

int CLI::cmd_help() {
    std::cout << R"(vm-state - Manage portable VM states

USAGE:
  vm-state <command> [arguments]

COMMANDS:
  list                        List all states and slot assignments
  create <name>               Create a new empty state
  snapshot <slot> <name>      Snapshot current slot's state
  assign <slot> <state>       Assign a state to a slot
  clone <source> <dest>       Clone a state to a new name
  delete <name>               Delete a state (must not be in use)
  migrate <state> <slot>      Stop slot, assign state, start slot
  restore <snapshot> <state>  Restore a snapshot to a new state
  help                        Show this help

EXAMPLES:
  # List all states
  vm-state list

  # Create a new development environment
  vm-state create dev-env

  # Snapshot slot1's current state
  vm-state snapshot slot1 before-update

  # Run the dev-env state on slot2
  vm-state assign slot2 dev-env
  systemctl restart microvm@slot2

  # Clone production to test
  vm-state clone prod-env test-env
  vm-state migrate test-env slot3

  # Restore a snapshot
  vm-state restore before-update recovered-state

ARCHITECTURE:
  Slots are fixed network identities:
    slot1 = 10.1.0.2, slot2 = 10.2.0.2, ..., slot5 = 10.5.0.2

  States are portable persistent data stored as ZFS datasets:
    /var/lib/microvms/states/<state-name>/

  Any state can run on any slot. States can be:
    - Snapshotted for backup/rollback
    - Cloned for experimentation
    - Migrated between slots
)";
    return 0;
}

} // namespace vmstate
