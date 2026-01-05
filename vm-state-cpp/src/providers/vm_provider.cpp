#include "providers/vm_provider.hpp"
#include "providers/systemd_dbus_vm_provider.hpp"

namespace vmstate {

std::unique_ptr<VMProvider> VMProvider::create_default() {
    return std::make_unique<SystemdDBusVMProvider>();
}

} // namespace vmstate
