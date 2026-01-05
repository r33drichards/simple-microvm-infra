#include "cli/cli.hpp"
#include "providers/vm_provider.hpp"
#include "providers/state_provider.hpp"
#include <iostream>

int main(int argc, char* argv[]) {
    try {
        auto vm_provider = vmstate::VMProvider::create_default();
        auto state_provider = vmstate::StateProvider::create_default();

        vmstate::CLI cli(std::move(vm_provider), std::move(state_provider));
        return cli.run(argc, argv);
    } catch (const std::exception& e) {
        std::cerr << "[ERROR] " << e.what() << std::endl;
        return 1;
    }
}
