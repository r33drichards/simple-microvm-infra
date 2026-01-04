#pragma once

#include <string>
#include <vector>
#include <optional>
#include <filesystem>
#include <memory>
#include <unordered_map>

namespace vmstate {

// Forward declarations for libzfs types
struct libzfs_handle;
typedef struct libzfs_handle libzfs_handle_t;

/// Slot identifiers (fixed network identities)
enum class Slot {
    Slot1,
    Slot2,
    Slot3,
    Slot4,
    Slot5
};

/// Get slot name as string
std::string slot_to_string(Slot slot);

/// Parse slot from string
std::optional<Slot> slot_from_string(const std::string& s);

/// Get slot IP address
std::string slot_ip(Slot slot);

/// Get all slots
std::vector<Slot> all_slots();

/// Information about a slot
struct SlotInfo {
    Slot slot;
    std::string assigned_state;
    bool running;
};

/// Information about a state (ZFS dataset)
struct StateInfo {
    std::string name;
    uint64_t used_bytes;
    uint64_t available_bytes;
    std::string zfs_dataset;
};

/// Information about a snapshot
struct SnapshotInfo {
    std::string state_name;
    std::string snapshot_name;
    std::string full_name;
    uint64_t used_bytes;
};

/// Configuration for the backend
struct Config {
    std::filesystem::path states_dir = "/var/lib/microvms/states";
    std::filesystem::path microvms_dir = "/var/lib/microvms";
    std::filesystem::path assignments_file = "/etc/vm-state-assignments.json";
    std::string zfs_pool = "microvms";
    std::string zfs_dataset = "storage/states";
};

/// Abstract backend interface for VM state management
class VmStateBackend {
public:
    virtual ~VmStateBackend() = default;

    // Query operations
    virtual std::vector<SlotInfo> list_slots() = 0;
    virtual std::vector<StateInfo> list_states() = 0;
    virtual std::vector<SnapshotInfo> list_snapshots() = 0;
    virtual std::string get_slot_state(Slot slot) = 0;
    virtual bool is_slot_running(Slot slot) = 0;
    virtual bool state_exists(const std::string& state) = 0;

    // State management
    virtual void create_state(const std::string& state) = 0;
    virtual void delete_state(const std::string& state) = 0;
    virtual void clone_state(const std::string& source, const std::string& dest) = 0;

    // Snapshot operations
    virtual void snapshot(Slot slot, const std::string& snapshot_name) = 0;
    virtual void restore_snapshot(const std::string& snapshot_name, const std::string& new_state) = 0;

    // Slot assignment
    virtual void assign(Slot slot, const std::string& state) = 0;
    virtual void migrate(const std::string& state, Slot slot) = 0;

    // Slot control
    virtual void start_slot(Slot slot) = 0;
    virtual void stop_slot(Slot slot) = 0;
    virtual void restart_slot(Slot slot) = 0;
};

/// Local ZFS backend implementation using libzfs
class LocalZfsBackend : public VmStateBackend {
public:
    explicit LocalZfsBackend(const Config& config = Config{});
    ~LocalZfsBackend() override;

    // Prevent copying
    LocalZfsBackend(const LocalZfsBackend&) = delete;
    LocalZfsBackend& operator=(const LocalZfsBackend&) = delete;

    // Query operations
    std::vector<SlotInfo> list_slots() override;
    std::vector<StateInfo> list_states() override;
    std::vector<SnapshotInfo> list_snapshots() override;
    std::string get_slot_state(Slot slot) override;
    bool is_slot_running(Slot slot) override;
    bool state_exists(const std::string& state) override;

    // State management
    void create_state(const std::string& state) override;
    void delete_state(const std::string& state) override;
    void clone_state(const std::string& source, const std::string& dest) override;

    // Snapshot operations
    void snapshot(Slot slot, const std::string& snapshot_name) override;
    void restore_snapshot(const std::string& snapshot_name, const std::string& new_state) override;

    // Slot assignment
    void assign(Slot slot, const std::string& state) override;
    void migrate(const std::string& state, Slot slot) override;

    // Slot control
    void start_slot(Slot slot) override;
    void stop_slot(Slot slot) override;
    void restart_slot(Slot slot) override;

private:
    Config config_;
    libzfs_handle_t* zfs_handle_;

    std::string dataset_path(const std::string& state) const;
    std::string base_dataset() const;
    std::filesystem::path state_dir(const std::string& state) const;
    std::filesystem::path slot_dir(Slot slot) const;
    std::filesystem::path slot_data_img(Slot slot) const;
    std::filesystem::path state_data_img(const std::string& state) const;

    std::unordered_map<std::string, std::string> load_assignments();
    void save_assignments(const std::unordered_map<std::string, std::string>& assignments);

    void systemctl(const std::string& action, Slot slot);
    void set_ownership(const std::filesystem::path& path);

    int run_command(const std::string& cmd);
    std::string run_command_output(const std::string& cmd);
};

/// Exception for vm-state errors
class VmStateError : public std::runtime_error {
public:
    explicit VmStateError(const std::string& msg) : std::runtime_error(msg) {}
};

} // namespace vmstate
