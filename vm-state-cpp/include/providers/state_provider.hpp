#pragma once

#include <string>
#include <vector>
#include <optional>
#include <memory>
#include <cstdint>

namespace vmstate {

/**
 * StateInfo - Information about a state
 */
struct StateInfo {
    std::string name;
    std::string path;           // Mount path
    uint64_t used_bytes;        // Used space
    uint64_t available_bytes;   // Available space
    std::string dataset;        // Backend dataset name (e.g., ZFS dataset)
};

/**
 * SnapshotInfo - Information about a snapshot
 */
struct SnapshotInfo {
    std::string name;           // Snapshot name
    std::string state_name;     // Parent state name
    std::string full_name;      // Full identifier (e.g., "state@snapshot")
    std::string creation_time;  // Creation timestamp
    uint64_t size_bytes;        // Referenced size
};

/**
 * SlotAssignment - Mapping of slot to state
 */
struct SlotAssignment {
    std::string slot_name;
    std::string state_name;
};

/**
 * StateProvider - Abstract interface for state/snapshot management
 *
 * Implementations can use ZFS, LVM, btrfs, or other storage backends.
 */
class StateProvider {
public:
    virtual ~StateProvider() = default;

    // ========== State Management ==========

    /**
     * Create a new empty state
     * @param name State name
     * @return true if successful
     */
    virtual bool create_state(const std::string& name) = 0;

    /**
     * Delete a state
     * @param name State name
     * @param force Skip safety checks (dangerous!)
     * @return true if successful
     */
    virtual bool delete_state(const std::string& name, bool force = false) = 0;

    /**
     * Clone a state to a new state
     * @param source Source state name
     * @param dest Destination state name
     * @return true if successful
     */
    virtual bool clone_state(const std::string& source, const std::string& dest) = 0;

    /**
     * Check if a state exists
     * @param name State name
     * @return true if exists
     */
    virtual bool state_exists(const std::string& name) = 0;

    /**
     * Get state info
     * @param name State name
     * @return StateInfo if exists
     */
    virtual std::optional<StateInfo> get_state_info(const std::string& name) = 0;

    /**
     * List all states
     * @return Vector of state info
     */
    virtual std::vector<StateInfo> list_states() = 0;

    // ========== Snapshot Management ==========

    /**
     * Create a snapshot of a state
     * @param state_name State to snapshot
     * @param snapshot_name Name for the snapshot
     * @return true if successful
     */
    virtual bool create_snapshot(const std::string& state_name,
                                  const std::string& snapshot_name) = 0;

    /**
     * Delete a snapshot
     * @param state_name Parent state
     * @param snapshot_name Snapshot name
     * @return true if successful
     */
    virtual bool delete_snapshot(const std::string& state_name,
                                  const std::string& snapshot_name) = 0;

    /**
     * Restore a snapshot to a new state
     * @param snapshot_name Name of snapshot to restore
     * @param new_state_name Name for the new state
     * @return true if successful
     */
    virtual bool restore_snapshot(const std::string& snapshot_name,
                                   const std::string& new_state_name) = 0;

    /**
     * List snapshots for a state (or all if state_name is empty)
     * @param state_name Optional state to filter by
     * @return Vector of snapshot info
     */
    virtual std::vector<SnapshotInfo> list_snapshots(
        const std::string& state_name = "") = 0;

    /**
     * Find a snapshot by name (searches all states)
     * @param snapshot_name Name to find
     * @return SnapshotInfo if found
     */
    virtual std::optional<SnapshotInfo> find_snapshot(
        const std::string& snapshot_name) = 0;

    // ========== Assignment Management ==========

    /**
     * Get the state assigned to a slot
     * @param slot_name Slot name
     * @return State name (defaults to slot name if unassigned)
     */
    virtual std::string get_slot_state(const std::string& slot_name) = 0;

    /**
     * Assign a state to a slot
     * @param slot_name Slot name
     * @param state_name State name
     * @return true if successful
     */
    virtual bool assign_state(const std::string& slot_name,
                               const std::string& state_name) = 0;

    /**
     * List all slot assignments
     * @return Vector of slot->state mappings
     */
    virtual std::vector<SlotAssignment> list_assignments() = 0;

    /**
     * Check if a state is assigned to any slot
     * @param state_name State to check
     * @return Slot name if assigned, empty optional otherwise
     */
    virtual std::optional<std::string> is_state_in_use(
        const std::string& state_name) = 0;

    // ========== Utility ==========

    /**
     * Get the last error message
     * @return Error message string
     */
    virtual std::string get_last_error() const = 0;

    /**
     * Get the base states directory
     * @return Path to states directory
     */
    virtual std::string get_states_dir() const = 0;

    /**
     * Factory method to create the default state provider
     */
    static std::unique_ptr<StateProvider> create_default();
};

} // namespace vmstate
