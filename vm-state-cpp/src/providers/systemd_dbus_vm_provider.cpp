#include "providers/systemd_dbus_vm_provider.hpp"
#include <cstring>
#include <iostream>

namespace vmstate {

SystemdDBusVMProvider::SystemdDBusVMProvider(
    const std::string& service_prefix,
    const std::set<std::string>& valid_slots)
    : service_prefix_(service_prefix),
      valid_slots_(valid_slots) {
    init_bus();
}

SystemdDBusVMProvider::~SystemdDBusVMProvider() {
    cleanup_bus();
}

bool SystemdDBusVMProvider::init_bus() {
    int r = sd_bus_open_system(&bus_);
    if (r < 0) {
        last_error_ = "Failed to connect to system bus: " +
                      std::string(strerror(-r));
        return false;
    }
    return true;
}

void SystemdDBusVMProvider::cleanup_bus() {
    if (bus_) {
        sd_bus_unref(bus_);
        bus_ = nullptr;
    }
}

std::string SystemdDBusVMProvider::get_unit_name(
    const std::string& slot_name) const {
    return service_prefix_ + slot_name + ".service";
}

bool SystemdDBusVMProvider::call_unit_method(
    const std::string& method,
    const std::string& unit_name) {
    if (!bus_) {
        last_error_ = "D-Bus connection not initialized";
        return false;
    }

    sd_bus_error error = SD_BUS_ERROR_NULL;
    sd_bus_message* m = nullptr;

    int r = sd_bus_call_method(
        bus_,
        "org.freedesktop.systemd1",
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
        method.c_str(),
        &error,
        &m,
        "ss",
        unit_name.c_str(),
        "replace"  // Mode: replace existing job
    );

    if (r < 0) {
        last_error_ = "Failed to call " + method + ": " +
                      (error.message ? error.message : strerror(-r));
        sd_bus_error_free(&error);
        sd_bus_message_unref(m);
        return false;
    }

    sd_bus_error_free(&error);
    sd_bus_message_unref(m);
    return true;
}

std::optional<std::string> SystemdDBusVMProvider::get_unit_property(
    const std::string& unit_name,
    const std::string& property) {
    if (!bus_) {
        last_error_ = "D-Bus connection not initialized";
        return std::nullopt;
    }

    // First, get the unit object path
    sd_bus_error error = SD_BUS_ERROR_NULL;
    sd_bus_message* m = nullptr;
    const char* path = nullptr;

    int r = sd_bus_call_method(
        bus_,
        "org.freedesktop.systemd1",
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
        "GetUnit",
        &error,
        &m,
        "s",
        unit_name.c_str()
    );

    if (r < 0) {
        // Unit might not be loaded - try LoadUnit instead
        sd_bus_error_free(&error);
        sd_bus_message_unref(m);
        error = SD_BUS_ERROR_NULL;
        m = nullptr;

        r = sd_bus_call_method(
            bus_,
            "org.freedesktop.systemd1",
            "/org/freedesktop/systemd1",
            "org.freedesktop.systemd1.Manager",
            "LoadUnit",
            &error,
            &m,
            "s",
            unit_name.c_str()
        );

        if (r < 0) {
            last_error_ = "Failed to load unit: " +
                          (error.message ? error.message : strerror(-r));
            sd_bus_error_free(&error);
            sd_bus_message_unref(m);
            return std::nullopt;
        }
    }

    r = sd_bus_message_read(m, "o", &path);
    if (r < 0) {
        last_error_ = "Failed to parse unit path";
        sd_bus_error_free(&error);
        sd_bus_message_unref(m);
        return std::nullopt;
    }

    std::string unit_path(path);
    sd_bus_error_free(&error);
    sd_bus_message_unref(m);

    // Now get the property
    error = SD_BUS_ERROR_NULL;
    m = nullptr;

    r = sd_bus_get_property(
        bus_,
        "org.freedesktop.systemd1",
        unit_path.c_str(),
        "org.freedesktop.systemd1.Unit",
        property.c_str(),
        &error,
        &m,
        "s"
    );

    if (r < 0) {
        last_error_ = "Failed to get property: " +
                      (error.message ? error.message : strerror(-r));
        sd_bus_error_free(&error);
        sd_bus_message_unref(m);
        return std::nullopt;
    }

    const char* value = nullptr;
    r = sd_bus_message_read(m, "s", &value);
    if (r < 0) {
        last_error_ = "Failed to parse property value";
        sd_bus_error_free(&error);
        sd_bus_message_unref(m);
        return std::nullopt;
    }

    std::string result(value);
    sd_bus_error_free(&error);
    sd_bus_message_unref(m);
    return result;
}

bool SystemdDBusVMProvider::start(const std::string& slot_name) {
    if (!is_valid_slot(slot_name)) {
        last_error_ = "Invalid slot name: " + slot_name;
        return false;
    }
    return call_unit_method("StartUnit", get_unit_name(slot_name));
}

bool SystemdDBusVMProvider::stop(const std::string& slot_name) {
    if (!is_valid_slot(slot_name)) {
        last_error_ = "Invalid slot name: " + slot_name;
        return false;
    }
    return call_unit_method("StopUnit", get_unit_name(slot_name));
}

bool SystemdDBusVMProvider::restart(const std::string& slot_name) {
    if (!is_valid_slot(slot_name)) {
        last_error_ = "Invalid slot name: " + slot_name;
        return false;
    }
    return call_unit_method("RestartUnit", get_unit_name(slot_name));
}

bool SystemdDBusVMProvider::is_running(const std::string& slot_name) {
    return get_status(slot_name) == VMStatus::Running;
}

VMStatus SystemdDBusVMProvider::get_status(const std::string& slot_name) {
    if (!is_valid_slot(slot_name)) {
        last_error_ = "Invalid slot name: " + slot_name;
        return VMStatus::Unknown;
    }

    auto active_state = get_unit_property(get_unit_name(slot_name), "ActiveState");
    if (!active_state) {
        return VMStatus::Unknown;
    }

    if (*active_state == "active" || *active_state == "activating") {
        return VMStatus::Running;
    } else if (*active_state == "inactive" || *active_state == "deactivating") {
        return VMStatus::Stopped;
    } else if (*active_state == "failed") {
        return VMStatus::Failed;
    }

    return VMStatus::Unknown;
}

std::optional<VMInfo> SystemdDBusVMProvider::get_info(
    const std::string& slot_name) {
    if (!is_valid_slot(slot_name)) {
        last_error_ = "Invalid slot name: " + slot_name;
        return std::nullopt;
    }

    VMInfo info;
    info.slot_name = slot_name;
    info.status = get_status(slot_name);

    // Extract slot number and derive IP
    if (slot_name.size() > 4 && slot_name.substr(0, 4) == "slot") {
        try {
            int slot_num = std::stoi(slot_name.substr(4));
            info.ip_address = "10." + std::to_string(slot_num) + ".0.2";
        } catch (...) {
            info.ip_address = "unknown";
        }
    }

    // State name would need to come from StateProvider
    info.state_name = slot_name;  // Default

    return info;
}

std::vector<std::string> SystemdDBusVMProvider::list_slots() {
    return std::vector<std::string>(valid_slots_.begin(), valid_slots_.end());
}

bool SystemdDBusVMProvider::is_valid_slot(const std::string& slot_name) {
    return valid_slots_.find(slot_name) != valid_slots_.end();
}

std::string SystemdDBusVMProvider::get_last_error() const {
    return last_error_;
}

} // namespace vmstate
