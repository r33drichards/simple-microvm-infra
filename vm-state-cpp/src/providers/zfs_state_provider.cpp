#include "providers/zfs_state_provider.hpp"
#include "utils/json.hpp"
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <grp.h>
#include <pwd.h>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/nvpair.h>

namespace fs = std::filesystem;

namespace vmstate {

// Helper struct for collecting datasets during iteration
struct DatasetCollector {
    std::vector<StateInfo>* states;
    std::string base_path;
    libzfs_handle_t* zfs_handle;
};

// Helper struct for collecting snapshots during iteration
struct SnapshotCollector {
    std::vector<SnapshotInfo>* snapshots;
    std::string base_path;
};

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
      slots_(slots) {
    init_libzfs();
}

ZFSStateProvider::~ZFSStateProvider() {
    if (zfs_handle_) {
        libzfs_fini(zfs_handle_);
        zfs_handle_ = nullptr;
    }
}

bool ZFSStateProvider::init_libzfs() {
    zfs_handle_ = libzfs_init();
    if (!zfs_handle_) {
        last_error_ = "Failed to initialize libzfs";
        return false;
    }
    return true;
}

std::string ZFSStateProvider::get_dataset_path(
    const std::string& state_name) const {
    return pool_ + "/" + base_dataset_ + "/" + state_name;
}

std::string ZFSStateProvider::get_mount_path(
    const std::string& state_name) const {
    return states_dir_ + "/" + state_name;
}

zfs_handle_t* ZFSStateProvider::open_dataset(const std::string& name, int type) const {
    if (!zfs_handle_) {
        return nullptr;
    }
    return zfs_open(zfs_handle_, name.c_str(), type);
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
    if (!zfs_handle_) {
        last_error_ = "libzfs not initialized";
        return false;
    }

    std::string dataset = get_dataset_path(name);
    std::string mountpoint = get_mount_path(name);

    // Check if already exists
    if (state_exists(name)) {
        last_error_ = "State '" + name + "' already exists";
        return false;
    }

    // Create nvlist for properties
    nvlist_t* props = nullptr;
    if (nvlist_alloc(&props, NV_UNIQUE_NAME, 0) != 0) {
        last_error_ = "Failed to allocate nvlist for properties";
        return false;
    }

    // Set mountpoint property
    if (nvlist_add_string(props, zfs_prop_to_name(ZFS_PROP_MOUNTPOINT),
                          mountpoint.c_str()) != 0) {
        nvlist_free(props);
        last_error_ = "Failed to set mountpoint property";
        return false;
    }

    // Create the dataset
    int ret = zfs_create(zfs_handle_, dataset.c_str(), ZFS_TYPE_FILESYSTEM, props);
    nvlist_free(props);

    if (ret != 0) {
        last_error_ = "Failed to create dataset: " +
                      std::string(libzfs_error_description(zfs_handle_));
        return false;
    }

    // Set permissions
    if (!set_state_permissions(name)) {
        return false;
    }

    return true;
}

bool ZFSStateProvider::delete_state(const std::string& name, bool force) {
    if (!zfs_handle_) {
        last_error_ = "libzfs not initialized";
        return false;
    }

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

    // Open the dataset
    zfs_handle_t* zhp = open_dataset(dataset, ZFS_TYPE_FILESYSTEM);
    if (!zhp) {
        last_error_ = "Failed to open dataset: " +
                      std::string(libzfs_error_description(zfs_handle_));
        return false;
    }

    // Destroy recursively (handles snapshots)
    int ret = zfs_destroy(zhp, B_TRUE);  // B_TRUE = defer (recursive)
    zfs_close(zhp);

    if (ret != 0) {
        last_error_ = "Failed to destroy dataset: " +
                      std::string(libzfs_error_description(zfs_handle_));
        return false;
    }

    return true;
}

bool ZFSStateProvider::clone_state(const std::string& source,
                                    const std::string& dest) {
    if (!zfs_handle_) {
        last_error_ = "libzfs not initialized";
        return false;
    }

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
    std::string snap_name = "clone-for-" + dest;
    std::string full_snap = src_dataset + "@" + snap_name;

    // Open source dataset
    zfs_handle_t* src_zhp = open_dataset(src_dataset, ZFS_TYPE_FILESYSTEM);
    if (!src_zhp) {
        last_error_ = "Failed to open source dataset";
        return false;
    }

    // Create snapshot
    nvlist_t* snap_props = nullptr;
    nvlist_alloc(&snap_props, NV_UNIQUE_NAME, 0);

    int ret = zfs_snapshot(zfs_handle_, full_snap.c_str(), B_FALSE, snap_props);
    nvlist_free(snap_props);
    zfs_close(src_zhp);

    if (ret != 0) {
        last_error_ = "Failed to create snapshot: " +
                      std::string(libzfs_error_description(zfs_handle_));
        return false;
    }

    // Open the snapshot
    zfs_handle_t* snap_zhp = open_dataset(full_snap, ZFS_TYPE_SNAPSHOT);
    if (!snap_zhp) {
        last_error_ = "Failed to open snapshot for cloning";
        return false;
    }

    // Create clone properties
    nvlist_t* clone_props = nullptr;
    nvlist_alloc(&clone_props, NV_UNIQUE_NAME, 0);
    nvlist_add_string(clone_props, zfs_prop_to_name(ZFS_PROP_MOUNTPOINT),
                      dst_mount.c_str());

    // Clone from snapshot
    ret = zfs_clone(snap_zhp, dst_dataset.c_str(), clone_props);
    nvlist_free(clone_props);
    zfs_close(snap_zhp);

    if (ret != 0) {
        last_error_ = "Failed to clone dataset: " +
                      std::string(libzfs_error_description(zfs_handle_));
        return false;
    }

    // Promote the clone to an independent dataset
    zfs_handle_t* clone_zhp = open_dataset(dst_dataset, ZFS_TYPE_FILESYSTEM);
    if (!clone_zhp) {
        last_error_ = "Failed to open cloned dataset for promotion";
        return false;
    }

    ret = zfs_promote(clone_zhp);
    zfs_close(clone_zhp);

    if (ret != 0) {
        last_error_ = "Failed to promote clone: " +
                      std::string(libzfs_error_description(zfs_handle_));
        return false;
    }

    // Set permissions
    if (!set_state_permissions(dest)) {
        return false;
    }

    return true;
}

bool ZFSStateProvider::state_exists(const std::string& name) {
    if (!zfs_handle_) {
        return false;
    }

    std::string dataset = get_dataset_path(name);
    zfs_handle_t* zhp = zfs_open(zfs_handle_, dataset.c_str(), ZFS_TYPE_FILESYSTEM);
    if (zhp) {
        zfs_close(zhp);
        return true;
    }
    return false;
}

std::optional<StateInfo> ZFSStateProvider::get_state_info(
    const std::string& name) {
    if (!zfs_handle_) {
        return std::nullopt;
    }

    std::string dataset = get_dataset_path(name);
    zfs_handle_t* zhp = open_dataset(dataset, ZFS_TYPE_FILESYSTEM);
    if (!zhp) {
        return std::nullopt;
    }

    StateInfo info;
    info.name = name;
    info.path = get_mount_path(name);
    info.dataset = dataset;

    // Get used and available space
    info.used_bytes = zfs_prop_get_int(zhp, ZFS_PROP_USED);
    info.available_bytes = zfs_prop_get_int(zhp, ZFS_PROP_AVAILABLE);

    zfs_close(zhp);
    return info;
}

int ZFSStateProvider::dataset_iter_callback(zfs_handle_t* zhp, void* data) {
    auto* collector = static_cast<DatasetCollector*>(data);

    const char* name = zfs_get_name(zhp);
    std::string name_str(name);

    // Skip the base dataset itself
    if (name_str != collector->base_path) {
        // Extract state name from dataset path
        std::string state_name = name_str.substr(collector->base_path.size() + 1);

        // Skip nested datasets
        if (state_name.find('/') == std::string::npos) {
            StateInfo info;
            info.name = state_name;
            info.dataset = name_str;
            info.used_bytes = zfs_prop_get_int(zhp, ZFS_PROP_USED);
            info.available_bytes = zfs_prop_get_int(zhp, ZFS_PROP_AVAILABLE);

            char mountpoint[ZFS_MAXPROPLEN];
            if (zfs_prop_get(zhp, ZFS_PROP_MOUNTPOINT, mountpoint,
                            sizeof(mountpoint), nullptr, nullptr, 0, B_FALSE) == 0) {
                info.path = mountpoint;
            }

            collector->states->push_back(info);
        }
    }

    zfs_close(zhp);
    return 0;
}

std::vector<StateInfo> ZFSStateProvider::list_states() {
    std::vector<StateInfo> result;

    if (!zfs_handle_) {
        return result;
    }

    std::string base = pool_ + "/" + base_dataset_;
    zfs_handle_t* base_zhp = open_dataset(base, ZFS_TYPE_FILESYSTEM);
    if (!base_zhp) {
        return result;
    }

    DatasetCollector collector;
    collector.states = &result;
    collector.base_path = base;
    collector.zfs_handle = zfs_handle_;

    zfs_iter_filesystems(base_zhp, dataset_iter_callback, &collector);
    zfs_close(base_zhp);

    return result;
}

bool ZFSStateProvider::create_snapshot(const std::string& state_name,
                                         const std::string& snapshot_name) {
    if (!zfs_handle_) {
        last_error_ = "libzfs not initialized";
        return false;
    }

    if (!state_exists(state_name)) {
        last_error_ = "State '" + state_name + "' doesn't exist";
        return false;
    }

    std::string full_snap = get_dataset_path(state_name) + "@" + snapshot_name;

    nvlist_t* props = nullptr;
    nvlist_alloc(&props, NV_UNIQUE_NAME, 0);

    int ret = zfs_snapshot(zfs_handle_, full_snap.c_str(), B_FALSE, props);
    nvlist_free(props);

    if (ret != 0) {
        last_error_ = "Failed to create snapshot: " +
                      std::string(libzfs_error_description(zfs_handle_));
        return false;
    }

    return true;
}

bool ZFSStateProvider::delete_snapshot(const std::string& state_name,
                                         const std::string& snapshot_name) {
    if (!zfs_handle_) {
        last_error_ = "libzfs not initialized";
        return false;
    }

    std::string full_snap = get_dataset_path(state_name) + "@" + snapshot_name;
    zfs_handle_t* zhp = open_dataset(full_snap, ZFS_TYPE_SNAPSHOT);
    if (!zhp) {
        last_error_ = "Snapshot not found";
        return false;
    }

    int ret = zfs_destroy(zhp, B_FALSE);
    zfs_close(zhp);

    if (ret != 0) {
        last_error_ = "Failed to destroy snapshot: " +
                      std::string(libzfs_error_description(zfs_handle_));
        return false;
    }

    return true;
}

bool ZFSStateProvider::restore_snapshot(const std::string& snapshot_name,
                                          const std::string& new_state_name) {
    if (!zfs_handle_) {
        last_error_ = "libzfs not initialized";
        return false;
    }

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

    // Open the snapshot
    zfs_handle_t* snap_zhp = open_dataset(snap->full_name, ZFS_TYPE_SNAPSHOT);
    if (!snap_zhp) {
        last_error_ = "Failed to open snapshot";
        return false;
    }

    // Create clone properties
    nvlist_t* props = nullptr;
    nvlist_alloc(&props, NV_UNIQUE_NAME, 0);
    nvlist_add_string(props, zfs_prop_to_name(ZFS_PROP_MOUNTPOINT),
                      dst_mount.c_str());

    // Clone from snapshot
    int ret = zfs_clone(snap_zhp, dst_dataset.c_str(), props);
    nvlist_free(props);
    zfs_close(snap_zhp);

    if (ret != 0) {
        last_error_ = "Failed to clone from snapshot: " +
                      std::string(libzfs_error_description(zfs_handle_));
        return false;
    }

    // Promote to independent dataset
    zfs_handle_t* clone_zhp = open_dataset(dst_dataset, ZFS_TYPE_FILESYSTEM);
    if (!clone_zhp) {
        last_error_ = "Failed to open cloned dataset";
        return false;
    }

    ret = zfs_promote(clone_zhp);
    zfs_close(clone_zhp);

    if (ret != 0) {
        last_error_ = "Failed to promote clone: " +
                      std::string(libzfs_error_description(zfs_handle_));
        return false;
    }

    // Set permissions
    if (!set_state_permissions(new_state_name)) {
        return false;
    }

    return true;
}

int ZFSStateProvider::snapshot_iter_callback(zfs_handle_t* zhp, void* data) {
    auto* collector = static_cast<SnapshotCollector*>(data);

    const char* full_name = zfs_get_name(zhp);
    std::string full_name_str(full_name);

    // Find @ separator
    size_t at_pos = full_name_str.find('@');
    if (at_pos != std::string::npos) {
        std::string dataset = full_name_str.substr(0, at_pos);
        std::string snap_name = full_name_str.substr(at_pos + 1);

        // Extract state name
        std::string state_name;
        if (dataset.size() > collector->base_path.size() + 1) {
            state_name = dataset.substr(collector->base_path.size() + 1);
        }

        SnapshotInfo info;
        info.name = snap_name;
        info.state_name = state_name;
        info.full_name = full_name_str;
        info.size_bytes = zfs_prop_get_int(zhp, ZFS_PROP_REFERENCED);

        // Get creation time
        char creation[64];
        if (zfs_prop_get(zhp, ZFS_PROP_CREATION, creation,
                        sizeof(creation), nullptr, nullptr, 0, B_FALSE) == 0) {
            info.creation_time = creation;
        }

        collector->snapshots->push_back(info);
    }

    zfs_close(zhp);
    return 0;
}

std::vector<SnapshotInfo> ZFSStateProvider::list_snapshots(
    const std::string& state_name) {
    std::vector<SnapshotInfo> result;

    if (!zfs_handle_) {
        return result;
    }

    std::string base = pool_ + "/" + base_dataset_;
    std::string target = state_name.empty() ? base : get_dataset_path(state_name);

    zfs_handle_t* zhp = open_dataset(target, ZFS_TYPE_FILESYSTEM);
    if (!zhp) {
        return result;
    }

    SnapshotCollector collector;
    collector.snapshots = &result;
    collector.base_path = base;

    // If listing for a specific state, just iterate its snapshots
    // Otherwise, iterate all filesystems and their snapshots
    // Note: zfs_iter_snapshots takes (handle, simple, callback, data, min_txg, max_txg)
    // Use 0, 0 to iterate all snapshots without txg filtering
    if (!state_name.empty()) {
        zfs_iter_snapshots(zhp, B_FALSE, snapshot_iter_callback, &collector, 0, 0);
    } else {
        // Need to iterate all child filesystems and their snapshots
        zfs_iter_snapshots(zhp, B_FALSE, snapshot_iter_callback, &collector, 0, 0);

        // Also iterate child filesystems
        auto iter_children = [](zfs_handle_t* child_zhp, void* data) -> int {
            auto* coll = static_cast<SnapshotCollector*>(data);
            zfs_iter_snapshots(child_zhp, B_FALSE, snapshot_iter_callback, data, 0, 0);
            zfs_close(child_zhp);
            return 0;
        };
        zfs_iter_filesystems(zhp, iter_children, &collector);
    }

    zfs_close(zhp);
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
