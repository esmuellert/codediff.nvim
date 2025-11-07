cmake_minimum_required(VERSION 3.15)

# Export compile commands for clangd
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Read version from VERSION file (single source of truth)
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" PROJECT_VERSION)
string(STRIP "${PROJECT_VERSION}" PROJECT_VERSION)

project(vscode-diff-nvim VERSION ${PROJECT_VERSION})

# This is the root CMakeLists.txt for the Neovim plugin
# It delegates C building to libvscode-diff/

# Enable testing at root level so CTest can find tests from subdirectories
enable_testing()

# Add C core subdirectory
add_subdirectory(libvscode-diff)

message(STATUS "===========================================")
message(STATUS "  vscode-diff.nvim Plugin")
message(STATUS "===========================================")
message(STATUS "  Build the plugin:")
message(STATUS "    cmake -B build")
message(STATUS "    cmake --build build")
message(STATUS "")
message(STATUS "  Run C tests:")
message(STATUS "    cmake --build build --target test")
message(STATUS "    ctest --test-dir build")
message(STATUS "")
message(STATUS "  Run Lua tests:")
message(STATUS "    ./tests/run_tests.sh")
message(STATUS "    make test-lua")
message(STATUS "===========================================")

