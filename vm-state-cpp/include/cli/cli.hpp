#pragma once

#include "providers/vm_provider.hpp"
#include "providers/state_provider.hpp"
#include <memory>
#include <string>
#include <vector>
#include <functional>

namespace vmstate {

/**
 * CLI - Command line interface for vm-state
 *
 * Implements the same interface as the bash vm-state script.
 */
class CLI {
public:
    /**
     * Constructor
     * @param vm_provider VM management provider
     * @param state_provider State management provider
     */
    CLI(std::unique_ptr<VMProvider> vm_provider,
        std::unique_ptr<StateProvider> state_provider);

    ~CLI() = default;

    /**
     * Run the CLI with command line arguments
     * @param argc Argument count
     * @param argv Argument vector
     * @return Exit code (0 for success)
     */
    int run(int argc, char* argv[]);

private:
    // Command implementations
    int cmd_list();
    int cmd_create(const std::vector<std::string>& args);
    int cmd_snapshot(const std::vector<std::string>& args);
    int cmd_assign(const std::vector<std::string>& args);
    int cmd_clone(const std::vector<std::string>& args);
    int cmd_delete(const std::vector<std::string>& args);
    int cmd_migrate(const std::vector<std::string>& args);
    int cmd_restore(const std::vector<std::string>& args);
    int cmd_help();

    // Output helpers
    void info(const std::string& msg) const;
    void success(const std::string& msg) const;
    void warn(const std::string& msg) const;
    void error(const std::string& msg) const;

    // Check if running as root
    bool check_root() const;

    // Get VM status string
    std::string status_string(VMStatus status) const;

    std::unique_ptr<VMProvider> vm_provider_;
    std::unique_ptr<StateProvider> state_provider_;
    bool use_colors_ = true;
};

} // namespace vmstate
