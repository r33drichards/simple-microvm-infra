#pragma once

#include <string>
#include <vector>
#include <optional>

namespace vmstate {
namespace utils {

/**
 * ExecResult - Result of executing a command
 */
struct ExecResult {
    int exit_code;
    std::string stdout_output;
    std::string stderr_output;
};

/**
 * Execute a command and capture output
 * @param command Command to execute (full path recommended)
 * @param args Arguments (not including command itself)
 * @return ExecResult with exit code and output
 */
ExecResult exec(const std::string& command,
                const std::vector<std::string>& args);

/**
 * Execute a command without capturing output
 * @param command Command to execute
 * @param args Arguments
 * @return Exit code
 */
int exec_simple(const std::string& command,
                const std::vector<std::string>& args);

/**
 * Find a command in PATH
 * @param command Command name
 * @return Full path if found
 */
std::optional<std::string> which(const std::string& command);

} // namespace utils
} // namespace vmstate
