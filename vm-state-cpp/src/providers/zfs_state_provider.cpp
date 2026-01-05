#include "providers/zfs_state_provider.hpp"
#include "utils/exec.hpp"
#include "utils/json.hpp"
#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <grp.h>
#include <pwd.h>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace vmstate {

ZFSStateProvider::ZFSStateProvider(
    const std::string& pool,
    const std::string& base_dataset,
    const std::string& states_dir,
    const std::string& assignments_file,
    const std::vector<std::string>& slots)
    : pool_(pool),
      base_dataset_(base_dataset),
      states_dir_(states_dir),
      assignments_file_(assignments_file),
      slots_(slots) {}

std::string ZFSStateProvider::get_dataset_path(
    const std::string& state_name) const {
    return pool_ + "/" + base_dataset_ + "/" + state_name;
}

std::string ZFSStateProvider::get_mount_path(
    const std::string& state_name) const {
    return states_dir_ + "/" + state_name;
}

int ZFSStateProvider::run_zfs(const std::vector<std::string>& args,
                               std::string& output) const {
    auto result = utils::exec("zfs", args);
    output = result.stdout_output;
    if (result.exit_code != 0 && !result.stderr_output.empty()) {
        last_error_ = result.stderr_output;
    }
    return result.exit_code;
}

int ZFSStateProvider::run_zfs(const std::vector<std::string>& args) const {
    std::string output;
    return run_zfs(args, output);
}

std::map<std::string, std::string> ZFSStateProvider::load_assignments() const {
    auto result = utils::read_json_file(assignments_file_);
    if (result) {
        return *result;
    }
    return {};
}

bool ZFSStateProvider::save_assignments(
    const std::map<std::string, std::string>& assignments) const {
    return utils::write_json_file(assignments_file_, assignments);
}

bool ZFSStateProvider::set_state_permissions(
    const std::string& state_name) const {
    std::string path = get_mount_path(state_name);

    // Get microvm user and kvm group
    struct passwd* pw = getpwnam("microvm");
    struct group* gr = getgrnam("kvm");

    uid_t uid = pw ? pw->pw_uid : 0;
    gid_t gid = gr ? gr->gr_gid : 0;

    if (chown(path.c_str(), uid, gid) != 0) {
        last_error_ = "Failed to chown " + path;
        return false;
    }

    if (chmod(path.c_str(), 0755) != 0) {
        last_error_ = "Failed to chmod " + path;
        return false;
    }

    return true;
}

bool ZFSStateProvider::create_state_symlink(
    const std::string& slot_name,
    const std::string& state_name) const {
    std::string slot_dir = "/var/lib/microvms/" + slot_name;
    std::string slot_data = slot_dir + "/data.img";
    std::string state_data = get_mount_path(state_name) + "/data.img";

    // Ensure slot directory exists
    try {
        fs::create_directories(slot_dir);
    } catch (const std::exception& e) {
        last_error_ = "Failed to create slot directory: " + std::string(e.what());
        return false;
    }

    // Remove existing symlink or backup regular file
    // Use symlink_status to detect symlinks without following them
    std::error_code ec;
    auto status = fs::symlink_status(slot_data, ec);
    if (!ec && fs::exists(status)) {
        if (fs::is_symlink(status)) {
            fs::remove(slot_data, ec);
            if (ec) {
                last_error_ = "Failed to remove existing symlink: " + ec.message();
                return false;
            }
        } else if (fs::is_regular_file(status)) {
            fs::rename(slot_data, slot_data + ".backup", ec);
            if (ec) {
                last_error_ = "Failed to backup existing file: " + ec.message();
                return false;
            }
        }
    }

    // Create symlink
    try {
        fs::create_symlink(state_data, slot_data);
    } catch (const std::exception& e) {
        last_error_ = "Failed to create symlink: " + std::string(e.what());
        return false;
    }

    // Set ownership on slot directory
    struct passwd* pw = getpwnam("microvm");
    struct group* gr = getgrnam("kvm");
    if (pw && gr) {
        if (chown(slot_dir.c_str(), pw->pw_uid, gr->gr_gid) != 0) {
            // Continue even if chown fails (not critical)
        }
    }

    return true;
}

bool ZFSStateProvider::create_state(const std::string& name) {
    std::string dataset = get_dataset_path(name);
    std::string mountpoint = get_mount_path(name);

    // Check if already exists
    if (state_exists(name)) {
        last_error_ = "State '" + name + "' already exists";
        return false;
    }

    // Create ZFS dataset
    int r = run_zfs({"create", "-o", "mountpoint=" + mountpoint, dataset});
    if (r != 0) {
        return false;
    }

    // Set permissions
    if (!set_state_permissions(name)) {
        return false;
    }

    return true;
}

bool ZFSStateProvider::delete_state(const std::string& name, bool force) {
    if (!state_exists(name)) {
        last_error_ = "State '" + name + "' doesn't exist";
        return false;
    }

    // Check if in use (unless force)
    if (!force) {
        auto slot = is_state_in_use(name);
        if (slot) {
            last_error_ = "State '" + name + "' is assigned to " + *slot;
            return false;
        }
    }

    std::string dataset = get_dataset_path(name);

    // Delete all snapshots first
    auto snapshots = list_snapshots(name);
    for (const auto& snap : snapshots) {
        run_zfs({"destroy", snap.full_name});
    }

    // Delete the dataset
    int r = run_zfs({"destroy", dataset});
    return r == 0;
}

bool ZFSStateProvider::clone_state(const std::string& source,
                                    const std::string& dest) {
    if (!state_exists(source)) {
        last_error_ = "Source state '" + source + "' doesn't exist";
        return false;
    }

    if (state_exists(dest)) {
        last_error_ = "Destination state '" + dest + "' already exists";
        return false;
    }

    std::string src_dataset = get_dataset_path(source);
    std::string dst_dataset = get_dataset_path(dest);
    std::string dst_mount = get_mount_path(dest);

    // Create a snapshot for cloning
    std::string clone_snap = src_dataset + "@clone-for-" + dest;
    int r = run_zfs({"snapshot", clone_snap});
    if (r != 0) {
        return false;
    }

    // Clone from snapshot
    r = run_zfs({"clone", "-o", "mountpoint=" + dst_mount, clone_snap, dst_dataset});
    if (r != 0) {
        return false;
    }

    // Promote to independent dataset
    r = run_zfs({"promote", dst_dataset});
    if (r != 0) {
        return false;
    }

    // Set permissions
    if (!set_state_permissions(dest)) {
        return false;
    }

    return true;
}

bool ZFSStateProvider::state_exists(const std::string& name) {
    std::string output;
    int r = run_zfs({"list", "-H", get_dataset_path(name)}, output);
    return r == 0;
}

std::optional<StateInfo> ZFSStateProvider::get_state_info(
    const std::string& name) {
    std::string dataset = get_dataset_path(name);
    std::string output;

    int r = run_zfs({"list", "-H", "-o", "name,used,avail", dataset}, output);
    if (r != 0) {
        return std::nullopt;
    }

    // Parse output: name<tab>used<tab>avail
    std::istringstream ss(output);
    std::string ds_name, used, avail;
    ss >> ds_name >> used >> avail;

    StateInfo info;
    info.name = name;
    info.path = get_mount_path(name);
    info.dataset = dataset;

    // Parse sizes (handle K, M, G suffixes)
    auto parse_size = [](const std::string& s) -> uint64_t {
        if (s.empty()) return 0;
        double value = std::stod(s);
        char suffix = s.back();
        switch (suffix) {
            case 'K': return static_cast<uint64_t>(value * 1024);
            case 'M': return static_cast<uint64_t>(value * 1024 * 1024);
            case 'G': return static_cast<uint64_t>(value * 1024 * 1024 * 1024);
            case 'T': return static_cast<uint64_t>(value * 1024 * 1024 * 1024 * 1024);
            default: return static_cast<uint64_t>(value);
        }
    };

    try {
        info.used_bytes = parse_size(used);
        info.available_bytes = parse_size(avail);
    } catch (...) {
        info.used_bytes = 0;
        info.available_bytes = 0;
    }

    return info;
}

std::vector<StateInfo> ZFSStateProvider::list_states() {
    std::vector<StateInfo> result;
    std::string base = pool_ + "/" + base_dataset_;
    std::string output;

    int r = run_zfs({"list", "-H", "-o", "name,used,avail", "-r", base}, output);
    if (r != 0) {
        return result;
    }

    std::istringstream ss(output);
    std::string line;
    while (std::getline(ss, line)) {
        if (line.empty()) continue;

        std::istringstream line_ss(line);
        std::string name, used, avail;
        line_ss >> name >> used >> avail;

        // Skip the base dataset itself
        if (name == base) continue;

        // Extract state name from full dataset path
        std::string state_name = name.substr(base.size() + 1);
        // Skip nested datasets (snapshots show as separate)
        if (state_name.find('/') != std::string::npos) continue;

        auto info = get_state_info(state_name);
        if (info) {
            result.push_back(*info);
        }
    }

    return result;
}

bool ZFSStateProvider::create_snapshot(const std::string& state_name,
                                         const std::string& snapshot_name) {
    if (!state_exists(state_name)) {
        last_error_ = "State '" + state_name + "' doesn't exist";
        return false;
    }

    std::string full_snap = get_dataset_path(state_name) + "@" + snapshot_name;
    int r = run_zfs({"snapshot", full_snap});
    return r == 0;
}

bool ZFSStateProvider::delete_snapshot(const std::string& state_name,
                                         const std::string& snapshot_name) {
    std::string full_snap = get_dataset_path(state_name) + "@" + snapshot_name;
    int r = run_zfs({"destroy", full_snap});
    return r == 0;
}

bool ZFSStateProvider::restore_snapshot(const std::string& snapshot_name,
                                          const std::string& new_state_name) {
    // Find the snapshot
    auto snap = find_snapshot(snapshot_name);
    if (!snap) {
        last_error_ = "Snapshot '" + snapshot_name + "' not found";
        return false;
    }

    if (state_exists(new_state_name)) {
        last_error_ = "State '" + new_state_name + "' already exists";
        return false;
    }

    std::string dst_dataset = get_dataset_path(new_state_name);
    std::string dst_mount = get_mount_path(new_state_name);

    // Clone from snapshot
    int r = run_zfs({"clone", "-o", "mountpoint=" + dst_mount,
                     snap->full_name, dst_dataset});
    if (r != 0) {
        return false;
    }

    // Promote to independent dataset
    r = run_zfs({"promote", dst_dataset});
    if (r != 0) {
        return false;
    }

    // Set permissions
    if (!set_state_permissions(new_state_name)) {
        return false;
    }

    return true;
}

std::vector<SnapshotInfo> ZFSStateProvider::list_snapshots(
    const std::string& state_name) {
    std::vector<SnapshotInfo> result;
    std::string base = pool_ + "/" + base_dataset_;
    std::string target = state_name.empty() ? base : get_dataset_path(state_name);

    std::string output;
    int r = run_zfs({"list", "-H", "-t", "snapshot", "-o", "name,creation,refer",
                     "-r", target}, output);
    if (r != 0) {
        return result;
    }

    std::istringstream ss(output);
    std::string line;
    while (std::getline(ss, line)) {
        if (line.empty()) continue;

        std::istringstream line_ss(line);
        std::string full_name, creation, refer;
        line_ss >> full_name;
        // Creation time may have spaces, read rest and then size
        std::string rest;
        std::getline(line_ss, rest);
        // Simple parse: last token is size, rest is creation time
        size_t last_space = rest.rfind('\t');
        if (last_space != std::string::npos) {
            creation = rest.substr(0, last_space);
            refer = rest.substr(last_space + 1);
        }

        // Extract snapshot name and state name
        size_t at_pos = full_name.find('@');
        if (at_pos == std::string::npos) continue;

        std::string dataset = full_name.substr(0, at_pos);
        std::string snap_name = full_name.substr(at_pos + 1);

        // Extract state name from dataset
        std::string state = dataset.substr(base.size() + 1);

        SnapshotInfo info;
        info.name = snap_name;
        info.state_name = state;
        info.full_name = full_name;
        info.creation_time = creation;

        // Parse size
        try {
            double val = std::stod(refer);
            char suffix = refer.back();
            switch (suffix) {
                case 'K': info.size_bytes = static_cast<uint64_t>(val * 1024); break;
                case 'M': info.size_bytes = static_cast<uint64_t>(val * 1024 * 1024); break;
                case 'G': info.size_bytes = static_cast<uint64_t>(val * 1024 * 1024 * 1024); break;
                default: info.size_bytes = static_cast<uint64_t>(val); break;
            }
        } catch (...) {
            info.size_bytes = 0;
        }

        result.push_back(info);
    }

    return result;
}

std::optional<SnapshotInfo> ZFSStateProvider::find_snapshot(
    const std::string& snapshot_name) {
    auto snapshots = list_snapshots();
    for (const auto& snap : snapshots) {
        if (snap.name == snapshot_name) {
            return snap;
        }
    }
    return std::nullopt;
}

std::string ZFSStateProvider::get_slot_state(const std::string& slot_name) {
    auto assignments = load_assignments();
    auto it = assignments.find(slot_name);
    if (it != assignments.end()) {
        return it->second;
    }
    // Default: slot uses state with same name
    return slot_name;
}

bool ZFSStateProvider::assign_state(const std::string& slot_name,
                                      const std::string& state_name) {
    // Validate slot
    bool valid_slot = std::find(slots_.begin(), slots_.end(), slot_name) != slots_.end();
    if (!valid_slot) {
        last_error_ = "Invalid slot name: " + slot_name;
        return false;
    }

    // Create state if it doesn't exist
    if (!state_exists(state_name)) {
        if (!create_state(state_name)) {
            return false;
        }
    }

    // Update assignments
    auto assignments = load_assignments();
    assignments[slot_name] = state_name;
    if (!save_assignments(assignments)) {
        last_error_ = "Failed to save assignments";
        return false;
    }

    // Create symlink
    if (!create_state_symlink(slot_name, state_name)) {
        return false;
    }

    return true;
}

std::vector<SlotAssignment> ZFSStateProvider::list_assignments() {
    std::vector<SlotAssignment> result;
    auto assignments = load_assignments();

    for (const auto& slot : slots_) {
        SlotAssignment sa;
        sa.slot_name = slot;
        auto it = assignments.find(slot);
        sa.state_name = (it != assignments.end()) ? it->second : slot;
        result.push_back(sa);
    }

    return result;
}

std::optional<std::string> ZFSStateProvider::is_state_in_use(
    const std::string& state_name) {
    auto assignments = list_assignments();
    for (const auto& a : assignments) {
        if (a.state_name == state_name) {
            return a.slot_name;
        }
    }
    return std::nullopt;
}

std::string ZFSStateProvider::get_last_error() const {
    return last_error_;
}

std::string ZFSStateProvider::get_states_dir() const {
    return states_dir_;
}

} // namespace vmstate
