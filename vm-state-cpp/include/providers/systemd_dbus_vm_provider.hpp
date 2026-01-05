#pragma once

#include "vm_provider.hpp"
#include <systemd/sd-bus.h>
#include <set>

namespace vmstate {

/**
 * SystemdDBusVMProvider - VM management via systemd D-Bus API
 *
 * Controls microvm@<slot>.service units via the systemd bus interface.
 */
class SystemdDBusVMProvider : public VMProvider {
public:
    /**
     * Constructor
     * @param service_prefix Prefix for service units (default: "microvm@")
     * @param valid_slots Set of valid slot names
     */
    explicit SystemdDBusVMProvider(
        const std::string& service_prefix = "microvm@",
        const std::set<std::string>& valid_slots = {"slot1", "slot2", "slot3", "slot4", "slot5"}
    );

    ~SystemdDBusVMProvider() override;

    // VMProvider interface
    bool start(const std::string& slot_name) override;
    bool stop(const std::string& slot_name) override;
    bool restart(const std::string& slot_name) override;
    bool is_running(const std::string& slot_name) override;
    VMStatus get_status(const std::string& slot_name) override;
    std::optional<VMInfo> get_info(const std::string& slot_name) override;
    std::vector<std::string> list_slots() override;
    bool is_valid_slot(const std::string& slot_name) override;
    std::string get_last_error() const override;

private:
    /**
     * Get the full service unit name for a slot
     */
    std::string get_unit_name(const std::string& slot_name) const;

    /**
     * Call a systemd manager method that takes a unit name
     * @param method Method name (e.g., "StartUnit", "StopUnit")
     * @param unit_name Full unit name
     * @return true if successful
     */
    bool call_unit_method(const std::string& method,
                          const std::string& unit_name);

    /**
     * Get a property from a unit
     * @param unit_name Full unit name
     * @param property Property name
     * @return Property value as string
     */
    std::optional<std::string> get_unit_property(
        const std::string& unit_name,
        const std::string& property);

    /**
     * Initialize the D-Bus connection
     */
    bool init_bus();

    /**
     * Cleanup the D-Bus connection
     */
    void cleanup_bus();

    sd_bus* bus_ = nullptr;
    std::string service_prefix_;
    std::set<std::string> valid_slots_;
    mutable std::string last_error_;
};

} // namespace vmstate
