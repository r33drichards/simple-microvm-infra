#pragma once

#include <string>
#include <vector>
#include <optional>
#include <memory>

namespace vmstate {

/**
 * VMStatus - Status of a virtual machine slot
 */
enum class VMStatus {
    Running,
    Stopped,
    Failed,
    Unknown
};

/**
 * VMInfo - Information about a VM slot
 */
struct VMInfo {
    std::string slot_name;
    VMStatus status;
    std::string state_name;  // Currently assigned state
    std::string ip_address;
};

/**
 * VMProvider - Abstract interface for VM lifecycle management
 *
 * Implementations can use systemd D-Bus, libvirt, direct QEMU control, etc.
 */
class VMProvider {
public:
    virtual ~VMProvider() = default;

    /**
     * Start a VM slot
     * @param slot_name Name of the slot (e.g., "slot1")
     * @return true if successful, false otherwise
     */
    virtual bool start(const std::string& slot_name) = 0;

    /**
     * Stop a VM slot
     * @param slot_name Name of the slot
     * @return true if successful, false otherwise
     */
    virtual bool stop(const std::string& slot_name) = 0;

    /**
     * Restart a VM slot
     * @param slot_name Name of the slot
     * @return true if successful, false otherwise
     */
    virtual bool restart(const std::string& slot_name) = 0;

    /**
     * Check if a VM slot is running
     * @param slot_name Name of the slot
     * @return true if running, false otherwise
     */
    virtual bool is_running(const std::string& slot_name) = 0;

    /**
     * Get the status of a VM slot
     * @param slot_name Name of the slot
     * @return VMStatus enum value
     */
    virtual VMStatus get_status(const std::string& slot_name) = 0;

    /**
     * Get information about a VM slot
     * @param slot_name Name of the slot
     * @return VMInfo struct with slot details
     */
    virtual std::optional<VMInfo> get_info(const std::string& slot_name) = 0;

    /**
     * Get list of all available slots
     * @return Vector of slot names
     */
    virtual std::vector<std::string> list_slots() = 0;

    /**
     * Validate a slot name
     * @param slot_name Name to validate
     * @return true if valid slot name
     */
    virtual bool is_valid_slot(const std::string& slot_name) = 0;

    /**
     * Get the last error message
     * @return Error message string
     */
    virtual std::string get_last_error() const = 0;

    /**
     * Factory method to create the default VM provider
     */
    static std::unique_ptr<VMProvider> create_default();
};

} // namespace vmstate
