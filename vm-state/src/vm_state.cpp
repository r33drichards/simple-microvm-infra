#include "vm_state.hpp"

#include <libzfs.h>
#include <nlohmann/json.hpp>

#include <fstream>
#include <array>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <thread>
#include <chrono>
#include <unistd.h>
#include <sys/stat.h>
#include <pwd.h>
#include <grp.h>

namespace vmstate {

using json = nlohmann::json;

// Slot utilities
std::string slot_to_string(Slot slot) {
    switch (slot) {
        case Slot::Slot1: return "slot1";
        case Slot::Slot2: return "slot2";
        case Slot::Slot3: return "slot3";
        case Slot::Slot4: return "slot4";
        case Slot::Slot5: return "slot5";
    }
    return "unknown";
}

std::optional<Slot> slot_from_string(const std::string& s) {
    if (s == "slot1") return Slot::Slot1;
    if (s == "slot2") return Slot::Slot2;
    if (s == "slot3") return Slot::Slot3;
    if (s == "slot4") return Slot::Slot4;
    if (s == "slot5") return Slot::Slot5;
    return std::nullopt;
}

std::string slot_ip(Slot slot) {
    switch (slot) {
        case Slot::Slot1: return "10.1.0.2";
        case Slot::Slot2: return "10.2.0.2";
        case Slot::Slot3: return "10.3.0.2";
        case Slot::Slot4: return "10.4.0.2";
        case Slot::Slot5: return "10.5.0.2";
    }
    return "unknown";
}

std::vector<Slot> all_slots() {
    return {Slot::Slot1, Slot::Slot2, Slot::Slot3, Slot::Slot4, Slot::Slot5};
}

// LocalZfsBackend implementation

LocalZfsBackend::LocalZfsBackend(const Config& config)
    : config_(config), zfs_handle_(nullptr) {
    // Check if running as root
    if (geteuid() != 0) {
        throw VmStateError("Must run as root");
    }

    // Initialize libzfs
    zfs_handle_ = libzfs_init();
    if (!zfs_handle_) {
        throw VmStateError("Failed to initialize libzfs");
    }
}

LocalZfsBackend::~LocalZfsBackend() {
    if (zfs_handle_) {
        libzfs_fini(zfs_handle_);
    }
}

std::string LocalZfsBackend::dataset_path(const std::string& state) const {
    return config_.zfs_pool + "/" + config_.zfs_dataset + "/" + state;
}

std::string LocalZfsBackend::base_dataset() const {
    return config_.zfs_pool + "/" + config_.zfs_dataset;
}

std::filesystem::path LocalZfsBackend::state_dir(const std::string& state) const {
    return config_.states_dir / state;
}

std::filesystem::path LocalZfsBackend::slot_dir(Slot slot) const {
    return config_.microvms_dir / slot_to_string(slot);
}

std::filesystem::path LocalZfsBackend::slot_data_img(Slot slot) const {
    return slot_dir(slot) / "data.img";
}

std::filesystem::path LocalZfsBackend::state_data_img(const std::string& state) const {
    return state_dir(state) / "data.img";
}

std::unordered_map<std::string, std::string> LocalZfsBackend::load_assignments() {
    std::unordered_map<std::string, std::string> assignments;

    if (std::filesystem::exists(config_.assignments_file)) {
        std::ifstream f(config_.assignments_file);
        json j = json::parse(f);
        for (auto& [key, value] : j.items()) {
            assignments[key] = value.get<std::string>();
        }
    }

    return assignments;
}

void LocalZfsBackend::save_assignments(const std::unordered_map<std::string, std::string>& assignments) {
    json j = assignments;
    std::ofstream f(config_.assignments_file);
    f << j.dump(2);
}

int LocalZfsBackend::run_command(const std::string& cmd) {
    return system(cmd.c_str());
}

std::string LocalZfsBackend::run_command_output(const std::string& cmd) {
    std::array<char, 128> buffer;
    std::string result;
    std::unique_ptr<FILE, decltype(&pclose)> pipe(popen(cmd.c_str(), "r"), pclose);
    if (!pipe) {
        throw VmStateError("Failed to run command: " + cmd);
    }
    while (fgets(buffer.data(), buffer.size(), pipe.get()) != nullptr) {
        result += buffer.data();
    }
    return result;
}

void LocalZfsBackend::systemctl(const std::string& action, Slot slot) {
    std::string service = "microvm@" + slot_to_string(slot) + ".service";
    std::string cmd = "systemctl " + action + " " + service;
    if (run_command(cmd) != 0) {
        throw VmStateError("systemctl " + action + " failed for " + slot_to_string(slot));
    }
}

void LocalZfsBackend::set_ownership(const std::filesystem::path& path) {
    struct passwd* pw = getpwnam("microvm");
    struct group* gr = getgrnam("kvm");
    if (pw && gr) {
        chown(path.c_str(), pw->pw_uid, gr->gr_gid);
    }
    chmod(path.c_str(), 0755);
}

std::vector<SlotInfo> LocalZfsBackend::list_slots() {
    std::vector<SlotInfo> slots;
    auto assignments = load_assignments();

    for (Slot slot : all_slots()) {
        std::string slot_name = slot_to_string(slot);
        std::string state = slot_name; // default

        auto it = assignments.find(slot_name);
        if (it != assignments.end()) {
            state = it->second;
        }

        slots.push_back({
            .slot = slot,
            .assigned_state = state,
            .running = is_slot_running(slot)
        });
    }

    return slots;
}

std::vector<StateInfo> LocalZfsBackend::list_states() {
    std::vector<StateInfo> states;
    std::string base = base_dataset();

    zfs_handle_t* base_handle = zfs_open(zfs_handle_, base.c_str(), ZFS_TYPE_FILESYSTEM);
    if (!base_handle) {
        return states;
    }

    // Callback to collect child datasets
    auto callback = [](zfs_handle_t* zhp, void* data) -> int {
        auto* states_ptr = static_cast<std::vector<StateInfo>*>(data);

        const char* name = zfs_get_name(zhp);
        if (name) {
            std::string full_name(name);
            // Extract just the state name (last component)
            size_t pos = full_name.rfind('/');
            std::string state_name = (pos != std::string::npos) ? full_name.substr(pos + 1) : full_name;

            uint64_t used = zfs_prop_get_int(zhp, ZFS_PROP_USED);
            uint64_t avail = zfs_prop_get_int(zhp, ZFS_PROP_AVAILABLE);

            states_ptr->push_back({
                .name = state_name,
                .used_bytes = used,
                .available_bytes = avail,
                .zfs_dataset = full_name
            });
        }
        zfs_close(zhp);
        return 0;
    };

    zfs_iter_filesystems(base_handle, callback, &states);
    zfs_close(base_handle);

    return states;
}

std::vector<SnapshotInfo> LocalZfsBackend::list_snapshots() {
    std::vector<SnapshotInfo> snapshots;
    std::string base = base_dataset();

    zfs_handle_t* base_handle = zfs_open(zfs_handle_, base.c_str(), ZFS_TYPE_FILESYSTEM);
    if (!base_handle) {
        return snapshots;
    }

    // First iterate filesystems, then their snapshots
    auto fs_callback = [](zfs_handle_t* zhp, void* data) -> int {
        auto* snapshots_ptr = static_cast<std::vector<SnapshotInfo>*>(data);

        auto snap_callback = [](zfs_handle_t* snap_zhp, void* snap_data) -> int {
            auto* snaps = static_cast<std::vector<SnapshotInfo>*>(snap_data);

            const char* name = zfs_get_name(snap_zhp);
            if (name) {
                std::string full_name(name);
                size_t at_pos = full_name.rfind('@');
                if (at_pos != std::string::npos) {
                    std::string dataset = full_name.substr(0, at_pos);
                    std::string snap_name = full_name.substr(at_pos + 1);

                    size_t slash_pos = dataset.rfind('/');
                    std::string state_name = (slash_pos != std::string::npos)
                        ? dataset.substr(slash_pos + 1) : dataset;

                    uint64_t used = zfs_prop_get_int(snap_zhp, ZFS_PROP_USED);

                    snaps->push_back({
                        .state_name = state_name,
                        .snapshot_name = snap_name,
                        .full_name = full_name,
                        .used_bytes = used
                    });
                }
            }
            zfs_close(snap_zhp);
            return 0;
        };

        zfs_iter_snapshots(zhp, B_FALSE, snap_callback, snapshots_ptr);
        zfs_close(zhp);
        return 0;
    };

    zfs_iter_filesystems(base_handle, fs_callback, &snapshots);
    zfs_close(base_handle);

    return snapshots;
}

std::string LocalZfsBackend::get_slot_state(Slot slot) {
    auto assignments = load_assignments();
    std::string slot_name = slot_to_string(slot);

    auto it = assignments.find(slot_name);
    if (it != assignments.end()) {
        return it->second;
    }
    return slot_name; // default: slot uses same-named state
}

bool LocalZfsBackend::is_slot_running(Slot slot) {
    std::string service = "microvm@" + slot_to_string(slot) + ".service";
    std::string cmd = "systemctl is-active --quiet " + service;
    return run_command(cmd) == 0;
}

bool LocalZfsBackend::state_exists(const std::string& state) {
    std::string ds = dataset_path(state);
    zfs_handle_t* zhp = zfs_open(zfs_handle_, ds.c_str(), ZFS_TYPE_FILESYSTEM);
    if (zhp) {
        zfs_close(zhp);
        return true;
    }
    return false;
}

void LocalZfsBackend::create_state(const std::string& state) {
    if (state_exists(state)) {
        throw VmStateError("State '" + state + "' already exists");
    }

    std::string ds = dataset_path(state);
    auto mountpoint = state_dir(state);

    // Create dataset with mountpoint
    nvlist_t* props = fnvlist_alloc();
    fnvlist_add_string(props, "mountpoint", mountpoint.c_str());

    int ret = zfs_create(zfs_handle_, ds.c_str(), ZFS_TYPE_FILESYSTEM, props);
    fnvlist_free(props);

    if (ret != 0) {
        throw VmStateError("Failed to create dataset: " + ds);
    }

    set_ownership(mountpoint);
}

void LocalZfsBackend::delete_state(const std::string& state) {
    if (!state_exists(state)) {
        throw VmStateError("State '" + state + "' does not exist");
    }

    // Check if state is in use
    auto assignments = load_assignments();
    for (Slot slot : all_slots()) {
        std::string slot_name = slot_to_string(slot);
        std::string assigned = slot_name;
        auto it = assignments.find(slot_name);
        if (it != assignments.end()) {
            assigned = it->second;
        }
        if (assigned == state) {
            throw VmStateError("State '" + state + "' is assigned to " + slot_name);
        }
    }

    std::string ds = dataset_path(state);

    // Delete snapshots first
    auto snapshots = list_snapshots();
    for (const auto& snap : snapshots) {
        if (snap.state_name == state) {
            zfs_handle_t* snap_zhp = zfs_open(zfs_handle_, snap.full_name.c_str(), ZFS_TYPE_SNAPSHOT);
            if (snap_zhp) {
                zfs_destroy(snap_zhp, B_FALSE);
                zfs_close(snap_zhp);
            }
        }
    }

    // Delete dataset
    zfs_handle_t* zhp = zfs_open(zfs_handle_, ds.c_str(), ZFS_TYPE_FILESYSTEM);
    if (zhp) {
        if (zfs_destroy(zhp, B_FALSE) != 0) {
            zfs_close(zhp);
            throw VmStateError("Failed to destroy dataset: " + ds);
        }
        zfs_close(zhp);
    }
}

void LocalZfsBackend::clone_state(const std::string& source, const std::string& dest) {
    if (!state_exists(source)) {
        throw VmStateError("Source state '" + source + "' does not exist");
    }
    if (state_exists(dest)) {
        throw VmStateError("Destination state '" + dest + "' already exists");
    }

    std::string src_ds = dataset_path(source);
    std::string dst_ds = dataset_path(dest);
    auto dst_mountpoint = state_dir(dest);
    std::string clone_snap = src_ds + "@clone-for-" + dest;

    // Create snapshot for clone
    zfs_handle_t* src_zhp = zfs_open(zfs_handle_, src_ds.c_str(), ZFS_TYPE_FILESYSTEM);
    if (!src_zhp) {
        throw VmStateError("Failed to open source dataset");
    }

    if (zfs_snapshot(zfs_handle_, clone_snap.c_str(), B_FALSE, nullptr) != 0) {
        zfs_close(src_zhp);
        throw VmStateError("Failed to create snapshot: " + clone_snap);
    }
    zfs_close(src_zhp);

    // Clone from snapshot
    zfs_handle_t* snap_zhp = zfs_open(zfs_handle_, clone_snap.c_str(), ZFS_TYPE_SNAPSHOT);
    if (!snap_zhp) {
        throw VmStateError("Failed to open snapshot: " + clone_snap);
    }

    nvlist_t* props = fnvlist_alloc();
    fnvlist_add_string(props, "mountpoint", dst_mountpoint.c_str());

    if (zfs_clone(snap_zhp, dst_ds.c_str(), props) != 0) {
        fnvlist_free(props);
        zfs_close(snap_zhp);
        throw VmStateError("Failed to clone: " + clone_snap + " -> " + dst_ds);
    }
    fnvlist_free(props);
    zfs_close(snap_zhp);

    // Promote the clone
    zfs_handle_t* dst_zhp = zfs_open(zfs_handle_, dst_ds.c_str(), ZFS_TYPE_FILESYSTEM);
    if (dst_zhp) {
        zfs_promote(dst_zhp);
        zfs_close(dst_zhp);
    }

    set_ownership(dst_mountpoint);
}

void LocalZfsBackend::snapshot(Slot slot, const std::string& snapshot_name) {
    std::string state = get_slot_state(slot);
    if (!state_exists(state)) {
        throw VmStateError("State '" + state + "' does not exist");
    }

    std::string ds = dataset_path(state);
    std::string full_snap = ds + "@" + snapshot_name;

    if (zfs_snapshot(zfs_handle_, full_snap.c_str(), B_FALSE, nullptr) != 0) {
        throw VmStateError("Failed to create snapshot: " + full_snap);
    }
}

void LocalZfsBackend::restore_snapshot(const std::string& snapshot_name, const std::string& new_state) {
    if (state_exists(new_state)) {
        throw VmStateError("State '" + new_state + "' already exists");
    }

    // Find the snapshot
    auto snapshots = list_snapshots();
    std::string snap_full_name;
    for (const auto& snap : snapshots) {
        if (snap.snapshot_name == snapshot_name) {
            snap_full_name = snap.full_name;
            break;
        }
    }

    if (snap_full_name.empty()) {
        throw VmStateError("Snapshot '" + snapshot_name + "' not found");
    }

    std::string dst_ds = dataset_path(new_state);
    auto dst_mountpoint = state_dir(new_state);

    // Clone from snapshot
    zfs_handle_t* snap_zhp = zfs_open(zfs_handle_, snap_full_name.c_str(), ZFS_TYPE_SNAPSHOT);
    if (!snap_zhp) {
        throw VmStateError("Failed to open snapshot: " + snap_full_name);
    }

    nvlist_t* props = fnvlist_alloc();
    fnvlist_add_string(props, "mountpoint", dst_mountpoint.c_str());

    if (zfs_clone(snap_zhp, dst_ds.c_str(), props) != 0) {
        fnvlist_free(props);
        zfs_close(snap_zhp);
        throw VmStateError("Failed to clone snapshot");
    }
    fnvlist_free(props);
    zfs_close(snap_zhp);

    // Promote
    zfs_handle_t* dst_zhp = zfs_open(zfs_handle_, dst_ds.c_str(), ZFS_TYPE_FILESYSTEM);
    if (dst_zhp) {
        zfs_promote(dst_zhp);
        zfs_close(dst_zhp);
    }

    set_ownership(dst_mountpoint);
}

void LocalZfsBackend::assign(Slot slot, const std::string& state) {
    // Create state if it doesn't exist
    if (!state_exists(state)) {
        create_state(state);
    }

    // Update assignments
    auto assignments = load_assignments();
    assignments[slot_to_string(slot)] = state;
    save_assignments(assignments);

    // Create symlink from slot's data.img to state's data.img
    auto slot_d = slot_dir(slot);
    auto slot_data = slot_data_img(slot);
    auto state_data = state_data_img(state);

    std::filesystem::create_directories(slot_d);
    set_ownership(slot_d);

    // Handle existing data.img
    if (std::filesystem::is_symlink(slot_data)) {
        std::filesystem::remove(slot_data);
    } else if (std::filesystem::exists(slot_data)) {
        std::filesystem::rename(slot_data, slot_d / "data.img.backup");
    }

    // Create symlink
    std::filesystem::create_symlink(state_data, slot_data);
}

void LocalZfsBackend::migrate(const std::string& state, Slot slot) {
    // Stop slot if running
    if (is_slot_running(slot)) {
        stop_slot(slot);
        std::this_thread::sleep_for(std::chrono::seconds(2));
    }

    // Assign state
    assign(slot, state);

    // Start slot
    start_slot(slot);
}

void LocalZfsBackend::start_slot(Slot slot) {
    systemctl("start", slot);
}

void LocalZfsBackend::stop_slot(Slot slot) {
    systemctl("stop", slot);
}

void LocalZfsBackend::restart_slot(Slot slot) {
    systemctl("restart", slot);
}

} // namespace vmstate
