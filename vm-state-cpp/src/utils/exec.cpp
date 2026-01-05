#include "utils/exec.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <sstream>
#include <sys/wait.h>
#include <unistd.h>

namespace vmstate {
namespace utils {

ExecResult exec(const std::string& command,
                const std::vector<std::string>& args) {
    ExecResult result;
    result.exit_code = -1;

    // Build argument list
    std::vector<char*> c_args;
    c_args.push_back(const_cast<char*>(command.c_str()));
    for (const auto& arg : args) {
        c_args.push_back(const_cast<char*>(arg.c_str()));
    }
    c_args.push_back(nullptr);

    // Create pipes for stdout and stderr
    int stdout_pipe[2];
    int stderr_pipe[2];

    if (pipe(stdout_pipe) < 0 || pipe(stderr_pipe) < 0) {
        result.stderr_output = "Failed to create pipes";
        return result;
    }

    pid_t pid = fork();
    if (pid < 0) {
        result.stderr_output = "Fork failed";
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);
        close(stderr_pipe[0]);
        close(stderr_pipe[1]);
        return result;
    }

    if (pid == 0) {
        // Child process
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);

        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stderr_pipe[1], STDERR_FILENO);

        close(stdout_pipe[1]);
        close(stderr_pipe[1]);

        execvp(command.c_str(), c_args.data());
        _exit(127);  // exec failed
    }

    // Parent process
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);

    // Read output
    std::array<char, 4096> buffer;
    ssize_t bytes_read;

    while ((bytes_read = read(stdout_pipe[0], buffer.data(), buffer.size())) > 0) {
        result.stdout_output.append(buffer.data(), bytes_read);
    }
    close(stdout_pipe[0]);

    while ((bytes_read = read(stderr_pipe[0], buffer.data(), buffer.size())) > 0) {
        result.stderr_output.append(buffer.data(), bytes_read);
    }
    close(stderr_pipe[0]);

    // Wait for child
    int status;
    waitpid(pid, &status, 0);

    if (WIFEXITED(status)) {
        result.exit_code = WEXITSTATUS(status);
    }

    return result;
}

int exec_simple(const std::string& command,
                const std::vector<std::string>& args) {
    auto result = exec(command, args);
    return result.exit_code;
}

std::optional<std::string> which(const std::string& command) {
    // Check if command is already an absolute path
    if (!command.empty() && command[0] == '/') {
        if (access(command.c_str(), X_OK) == 0) {
            return command;
        }
        return std::nullopt;
    }

    // Search in PATH
    const char* path_env = getenv("PATH");
    if (!path_env) {
        path_env = "/usr/bin:/bin";
    }

    std::string path_str(path_env);
    std::istringstream path_stream(path_str);
    std::string dir;

    while (std::getline(path_stream, dir, ':')) {
        std::string full_path = dir + "/" + command;
        if (access(full_path.c_str(), X_OK) == 0) {
            return full_path;
        }
    }

    return std::nullopt;
}

} // namespace utils
} // namespace vmstate
