#include "providers/state_provider.hpp"
#include "providers/zfs_state_provider.hpp"

namespace vmstate {

std::unique_ptr<StateProvider> StateProvider::create_default() {
    return std::make_unique<ZFSStateProvider>();
}

} // namespace vmstate
