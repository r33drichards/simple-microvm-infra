cmake_minimum_required(VERSION 3.18)
project(vm-state VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Find required packages
find_package(PkgConfig REQUIRED)
pkg_check_modules(SYSTEMD REQUIRED libsystemd)
pkg_check_modules(LIBZFS REQUIRED libzfs)
# Note: libnvpair is included with libzfs, no separate pkg-config needed

# Create a static library for ZFS-dependent code
# This isolates the ZFS includes (which conflict with systemd headers) from the rest
add_library(zfs_provider STATIC
    src/providers/state_provider.cpp
    src/providers/zfs_state_provider.cpp
)
target_include_directories(zfs_provider PRIVATE
    ${CMAKE_SOURCE_DIR}/include
    ${LIBZFS_INCLUDE_DIRS}
)
target_link_libraries(zfs_provider PRIVATE ${LIBZFS_LIBRARIES})

# Main sources that use systemd (no ZFS includes here)
set(MAIN_SOURCES
    src/main.cpp
    src/providers/vm_provider.cpp
    src/providers/systemd_dbus_vm_provider.cpp
    src/cli/cli.cpp
    src/utils/exec.cpp
    src/utils/json.cpp
)

# Create executable
add_executable(vm-state ${MAIN_SOURCES})

# Include directories for main sources (no ZFS - avoids header conflicts)
target_include_directories(vm-state PRIVATE
    ${CMAKE_SOURCE_DIR}/include
    ${SYSTEMD_INCLUDE_DIRS}
)

# Link libraries
target_link_libraries(vm-state
    zfs_provider
    ${SYSTEMD_LIBRARIES}
    ${LIBZFS_LIBRARIES}
)

# Install
install(TARGETS vm-state DESTINATION bin)
