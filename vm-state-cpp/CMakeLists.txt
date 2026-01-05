cmake_minimum_required(VERSION 3.18)
project(vm-state VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Find required packages
find_package(PkgConfig REQUIRED)
pkg_check_modules(SYSTEMD REQUIRED libsystemd)
pkg_check_modules(LIBZFS REQUIRED libzfs)
pkg_check_modules(LIBNVPAIR REQUIRED libnvpair)

# Include directories
include_directories(${CMAKE_SOURCE_DIR}/include)
include_directories(${SYSTEMD_INCLUDE_DIRS})
include_directories(${LIBZFS_INCLUDE_DIRS})
include_directories(${LIBNVPAIR_INCLUDE_DIRS})

# Source files
set(SOURCES
    src/main.cpp
    src/providers/vm_provider.cpp
    src/providers/systemd_dbus_vm_provider.cpp
    src/providers/state_provider.cpp
    src/providers/zfs_state_provider.cpp
    src/cli/cli.cpp
    src/utils/exec.cpp
    src/utils/json.cpp
)

# Create executable
add_executable(vm-state ${SOURCES})

# Link libraries
target_link_libraries(vm-state
    ${SYSTEMD_LIBRARIES}
    ${LIBZFS_LIBRARIES}
    ${LIBNVPAIR_LIBRARIES}
)

# Install
install(TARGETS vm-state DESTINATION bin)
