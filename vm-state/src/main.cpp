#include "vm_state.hpp"

#include <iostream>
#include <iomanip>
#include <string>
#include <vector>
#include <cstring>

using namespace vmstate;

// ANSI color codes
const char* BLUE = "\033[0;34m";
const char* GREEN = "\033[0;32m";
const char* YELLOW = "\033[1;33m";
const char* RED = "\033[0;31m";
const char* NC = "\033[0m";

void info(const std::string& msg) {
    std::cout << BLUE << "[INFO]" << NC << " " << msg << std::endl;
}

void success(const std::string& msg) {
    std::cout << GREEN << "[OK]" << NC << " " << msg << std::endl;
}

void warn(const std::string& msg) {
    std::cout << YELLOW << "[WARN]" << NC << " " << msg << std::endl;
}

void error(const std::string& msg) {
    std::cerr << RED << "[ERROR]" << NC << " " << msg << std::endl;
}

std::string format_size(uint64_t bytes) {
    const uint64_t KB = 1024;
    const uint64_t MB = KB * 1024;
    const uint64_t GB = MB * 1024;
    const uint64_t TB = GB * 1024;

    char buf[32];
    if (bytes >= TB) {
        snprintf(buf, sizeof(buf), "%.1fT", static_cast<double>(bytes) / TB);
    } else if (bytes >= GB) {
        snprintf(buf, sizeof(buf), "%.1fG", static_cast<double>(bytes) / GB);
    } else if (bytes >= MB) {
        snprintf(buf, sizeof(buf), "%.1fM", static_cast<double>(bytes) / MB);
    } else if (bytes >= KB) {
        snprintf(buf, sizeof(buf), "%.1fK", static_cast<double>(bytes) / KB);
    } else {
        snprintf(buf, sizeof(buf), "%luB", bytes);
    }
    return buf;
}

void cmd_list(LocalZfsBackend& backend) {
    info("States and assignments:");
    std::cout << std::endl;

    std::cout << std::left
              << std::setw(15) << "SLOT"
              << std::setw(15) << "STATE"
              << std::setw(10) << "RUNNING"
              << "ZFS DATASET" << std::endl;
    std::cout << std::setw(15) << "----"
              << std::setw(15) << "-----"
              << std::setw(10) << "-------"
              << "-----------" << std::endl;

    for (const auto& slot_info : backend.list_slots()) {
        std::string running = slot_info.running ? "yes" : "no";
        std::string dataset = "microvms/storage/states/" + slot_info.assigned_state;
        std::cout << std::left
                  << std::setw(15) << slot_to_string(slot_info.slot)
                  << std::setw(15) << slot_info.assigned_state
                  << std::setw(10) << running
                  << dataset << std::endl;
    }

    std::cout << std::endl;
    info("Available states (ZFS datasets):");
    auto states = backend.list_states();
    if (states.empty()) {
        std::cout << "  (no states created yet)" << std::endl;
    } else {
        for (const auto& state : states) {
            std::cout << "  " << std::left << std::setw(20) << state.name
                      << " used: " << std::setw(8) << format_size(state.used_bytes)
                      << " avail: " << format_size(state.available_bytes) << std::endl;
        }
    }

    std::cout << std::endl;
    info("Snapshots:");
    auto snapshots = backend.list_snapshots();
    if (snapshots.empty()) {
        std::cout << "  (no snapshots)" << std::endl;
    } else {
        int count = 0;
        for (const auto& snap : snapshots) {
            if (count++ >= 20) {
                std::cout << "  ... and " << (snapshots.size() - 20) << " more" << std::endl;
                break;
            }
            std::cout << "  " << snap.full_name << std::endl;
        }
    }
}

void cmd_create(LocalZfsBackend& backend, const std::string& name) {
    info("Creating state '" + name + "'...");
    backend.create_state(name);
    success("State '" + name + "' created at /var/lib/microvms/states/" + name);
    info("Assign it to a slot with: vm-state assign <slot> " + name);
}

void cmd_snapshot(LocalZfsBackend& backend, const std::string& slot_str, const std::string& name) {
    auto slot = slot_from_string(slot_str);
    if (!slot) {
        throw VmStateError("Invalid slot: " + slot_str);
    }

    std::string state = backend.get_slot_state(*slot);

    if (backend.is_slot_running(*slot)) {
        warn(slot_str + " is running - snapshot will be crash-consistent");
        warn("For a clean snapshot, stop the slot first: systemctl stop microvm@" + slot_str);
    }

    info("Creating snapshot of state '" + state + "' (from " + slot_str + ")...");
    backend.snapshot(*slot, name);
    success("Snapshot created: microvms/storage/states/" + state + "@" + name);
}

void cmd_assign(LocalZfsBackend& backend, const std::string& slot_str, const std::string& state) {
    auto slot = slot_from_string(slot_str);
    if (!slot) {
        throw VmStateError("Invalid slot: " + slot_str);
    }

    bool was_running = backend.is_slot_running(*slot);
    if (was_running) {
        warn(slot_str + " is currently running. Assignment will take effect after restart.");
    }

    if (!backend.state_exists(state)) {
        warn("State '" + state + "' doesn't exist yet. Creating it...");
    }

    backend.assign(*slot, state);

    info("Created symlink: /var/lib/microvms/" + slot_str + "/data.img -> /var/lib/microvms/states/" + state + "/data.img");
    success("Assigned state '" + state + "' to " + slot_str);

    if (was_running) {
        info("Restart the slot to use the new state: systemctl restart microvm@" + slot_str);
    } else {
        info("Start the slot with: systemctl start microvm@" + slot_str);
    }
}

void cmd_clone(LocalZfsBackend& backend, const std::string& source, const std::string& dest) {
    info("Cloning state '" + source + "' to '" + dest + "'...");
    backend.clone_state(source, dest);
    success("State '" + source + "' cloned to '" + dest + "'");
    info("Assign it to a slot with: vm-state assign <slot> " + dest);
}

void cmd_delete(LocalZfsBackend& backend, const std::string& name) {
    warn("This will permanently delete state '" + name + "' and all its data!");
    std::cout << "Type 'DELETE' to confirm: ";
    std::string confirm;
    std::getline(std::cin, confirm);

    if (confirm != "DELETE") {
        throw VmStateError("Aborted");
    }

    info("Deleting state '" + name + "'...");
    backend.delete_state(name);
    success("State '" + name + "' deleted");
}

void cmd_migrate(LocalZfsBackend& backend, const std::string& state, const std::string& slot_str) {
    auto slot = slot_from_string(slot_str);
    if (!slot) {
        throw VmStateError("Invalid slot: " + slot_str);
    }

    info("Migrating state '" + state + "' to " + slot_str + "...");

    if (backend.is_slot_running(*slot)) {
        info("Stopping " + slot_str + "...");
    }

    backend.migrate(state, *slot);
    success("Migration complete. " + slot_str + " is now running state '" + state + "'");
}

void cmd_restore(LocalZfsBackend& backend, const std::string& snapshot, const std::string& state) {
    info("Restoring snapshot '" + snapshot + "' to state '" + state + "'...");
    backend.restore_snapshot(snapshot, state);
    success("Snapshot restored to state '" + state + "'");
    info("Assign it to a slot with: vm-state assign <slot> " + state);
}

void cmd_start(LocalZfsBackend& backend, const std::string& slot_str) {
    auto slot = slot_from_string(slot_str);
    if (!slot) {
        throw VmStateError("Invalid slot: " + slot_str);
    }

    info("Starting " + slot_str + "...");
    backend.start_slot(*slot);
    success(slot_str + " started");
}

void cmd_stop(LocalZfsBackend& backend, const std::string& slot_str) {
    auto slot = slot_from_string(slot_str);
    if (!slot) {
        throw VmStateError("Invalid slot: " + slot_str);
    }

    info("Stopping " + slot_str + "...");
    backend.stop_slot(*slot);
    success(slot_str + " stopped");
}

void cmd_restart(LocalZfsBackend& backend, const std::string& slot_str) {
    auto slot = slot_from_string(slot_str);
    if (!slot) {
        throw VmStateError("Invalid slot: " + slot_str);
    }

    info("Restarting " + slot_str + "...");
    backend.restart_slot(*slot);
    success(slot_str + " restarted");
}

void print_usage(const char* prog) {
    std::cout << "vm-state - Manage portable MicroVM states\n\n"
              << "USAGE:\n"
              << "  " << prog << " <command> [arguments]\n\n"
              << "COMMANDS:\n"
              << "  list                        List all states and slot assignments\n"
              << "  create <name>               Create a new empty state\n"
              << "  snapshot <slot> <name>      Snapshot current slot's state\n"
              << "  assign <slot> <state>       Assign a state to a slot\n"
              << "  clone <source> <dest>       Clone a state to a new name\n"
              << "  delete <name>               Delete a state (must not be in use)\n"
              << "  migrate <state> <slot>      Stop slot, assign state, start slot\n"
              << "  restore <snapshot> <state>  Restore a snapshot to a new state\n"
              << "  start <slot>                Start a slot\n"
              << "  stop <slot>                 Stop a slot\n"
              << "  restart <slot>              Restart a slot\n"
              << "  help                        Show this help\n\n"
              << "EXAMPLES:\n"
              << "  vm-state list\n"
              << "  vm-state snapshot slot1 before-update\n"
              << "  vm-state clone slot1 my-experiment\n"
              << "  vm-state migrate my-experiment slot3\n"
              << std::endl;
}

int main(int argc, char* argv[]) {
    try {
        std::string cmd = (argc > 1) ? argv[1] : "list";

        if (cmd == "help" || cmd == "--help" || cmd == "-h") {
            print_usage(argv[0]);
            return 0;
        }

        LocalZfsBackend backend;

        if (cmd == "list") {
            cmd_list(backend);
        } else if (cmd == "create") {
            if (argc < 3) {
                error("Usage: vm-state create <name>");
                return 1;
            }
            cmd_create(backend, argv[2]);
        } else if (cmd == "snapshot") {
            if (argc < 4) {
                error("Usage: vm-state snapshot <slot> <name>");
                return 1;
            }
            cmd_snapshot(backend, argv[2], argv[3]);
        } else if (cmd == "assign") {
            if (argc < 4) {
                error("Usage: vm-state assign <slot> <state>");
                return 1;
            }
            cmd_assign(backend, argv[2], argv[3]);
        } else if (cmd == "clone") {
            if (argc < 4) {
                error("Usage: vm-state clone <source> <dest>");
                return 1;
            }
            cmd_clone(backend, argv[2], argv[3]);
        } else if (cmd == "delete") {
            if (argc < 3) {
                error("Usage: vm-state delete <name>");
                return 1;
            }
            cmd_delete(backend, argv[2]);
        } else if (cmd == "migrate") {
            if (argc < 4) {
                error("Usage: vm-state migrate <state> <slot>");
                return 1;
            }
            cmd_migrate(backend, argv[2], argv[3]);
        } else if (cmd == "restore") {
            if (argc < 4) {
                error("Usage: vm-state restore <snapshot> <state>");
                return 1;
            }
            cmd_restore(backend, argv[2], argv[3]);
        } else if (cmd == "start") {
            if (argc < 3) {
                error("Usage: vm-state start <slot>");
                return 1;
            }
            cmd_start(backend, argv[2]);
        } else if (cmd == "stop") {
            if (argc < 3) {
                error("Usage: vm-state stop <slot>");
                return 1;
            }
            cmd_stop(backend, argv[2]);
        } else if (cmd == "restart") {
            if (argc < 3) {
                error("Usage: vm-state restart <slot>");
                return 1;
            }
            cmd_restart(backend, argv[2]);
        } else {
            error("Unknown command: " + cmd);
            print_usage(argv[0]);
            return 1;
        }

        return 0;
    } catch (const VmStateError& e) {
        error(e.what());
        return 1;
    } catch (const std::exception& e) {
        error(std::string("Unexpected error: ") + e.what());
        return 1;
    }
}
