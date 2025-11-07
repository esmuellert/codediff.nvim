applyTo:
  - "**/CMakeLists.txt"
  - Makefile
  - Makefile.win
  - build.cmd
  - build.sh
---

# Build System Files

**Important**: `Makefile`, `Makefile.win`, `build.cmd`, and `build.sh` are **generated files** created by CMake from `CMakeLists.txt`.

## Editing Rules

- ✅ **DO**: Edit `CMakeLists.txt` when you need to modify the build configuration
- ❌ **DON'T**: Edit `Makefile`, `Makefile.win`, `build.cmd`, or `build.sh` directly - your changes will be overwritten

When you modify `CMakeLists.txt`, regenerate the build files by running CMake.
