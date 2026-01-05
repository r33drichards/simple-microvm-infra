#pragma once

#include "state_provider.hpp"
#include <map>

namespace vmstate {

/**
 * ZFSStateProvider - State/snapshot management via ZFS
 *
 * Uses ZFS datasets for states and ZFS snapshots for point-in-time captures.
 */
class ZFSStateProvider : public StateProvider {
public:
    /**
     * Constructor
     * @param pool ZFS pool name
     * @param base_dataset Base dataset path (relative to pool)
     * @param states_dir Mount point for states
     * @param assignments_file Path to slot assignments JSON file
     * @param slots List of valid slot names
     */
    explicit ZFSStateProvider(
        const std::string& pool = "microvms",
        const std::string& base_dataset = "storage/states",
        const std::string& states_dir = "/var/lib/microvms/states",
        const std::string& assignments_file = "/etc/vm-state-assignments.json",
        const std::vector<std::string>& slots = {"slot1", "slot2", "slot3", "slot4", "slot5"}
    );

    ~ZFSStateProvider() override = default;

    // State management
    bool create_state(const std::string& name) override;
    bool delete_state(const std::string& name, bool force = false) override;
    bool clone_state(const std::string& source, const std::string& dest) override;
    bool state_exists(const std::string& name) override;
    std::optional<StateInfo> get_state_info(const std::string& name) override;
    std::vector<StateInfo> list_states() override;

    // Snapshot management
    bool create_snapshot(const std::string& state_name,
                          const std::string& snapshot_name) override;
    bool delete_snapshot(const std::string& state_name,
                          const std::string& snapshot_name) override;
    bool restore_snapshot(const std::string& snapshot_name,
                           const std::string& new_state_name) override;
    std::vector<SnapshotInfo> list_snapshots(
        const std::string& state_name = "") override;
    std::optional<SnapshotInfo> find_snapshot(
        const std::string& snapshot_name) override;

    // Assignment management
    std::string get_slot_state(const std::string& slot_name) override;
    bool assign_state(const std::string& slot_name,
                       const std::string& state_name) override;
    std::vector<SlotAssignment> list_assignments() override;
    std::optional<std::string> is_state_in_use(
        const std::string& state_name) override;

    // Utility
    std::string get_last_error() const override;
    std::string get_states_dir() const override;

private:
    /**
     * Get full dataset path for a state
     */
    std::string get_dataset_path(const std::string& state_name) const;

    /**
     * Get mount path for a state
     */
    std::string get_mount_path(const std::string& state_name) const;

    /**
     * Execute a ZFS command and return output
     * @param args Command arguments (excluding 'zfs')
     * @param output Output string to fill
     * @return Exit code
     */
    int run_zfs(const std::vector<std::string>& args,
                std::string& output) const;

    /**
     * Execute a ZFS command without capturing output
     * @param args Command arguments (excluding 'zfs')
     * @return Exit code
     */
    int run_zfs(const std::vector<std::string>& args) const;

    /**
     * Load assignments from JSON file
     */
    std::map<std::string, std::string> load_assignments() const;

    /**
     * Save assignments to JSON file
     */
    bool save_assignments(const std::map<std::string, std::string>& assignments) const;

    /**
     * Create symlink from slot data.img to state data.img
     */
    bool create_state_symlink(const std::string& slot_name,
                               const std::string& state_name) const;

    /**
     * Set proper ownership and permissions on state directory
     */
    bool set_state_permissions(const std::string& state_name) const;

    std::string pool_;
    std::string base_dataset_;
    std::string states_dir_;
    std::string assignments_file_;
    std::vector<std::string> slots_;
    mutable std::string last_error_;
};

} // namespace vmstate
