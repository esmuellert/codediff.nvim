# Automatic Library Installation System

This document describes the automatic installation system for the libvscode-diff C library.

## Overview

The automatic installation system downloads pre-built binaries from GitHub releases, eliminating the need for users to have a compiler installed. The system automatically detects the user's platform (OS and architecture) and downloads the appropriate binary.

## Architecture

### Components

1. **`lua/vscode-diff/installer.lua`**
   - Platform detection
   - Download management
   - VERSION file parsing
   - Error handling

2. **`lua/vscode-diff/diff.lua`**
   - Triggers auto-installation before FFI load
   - Provides fallback error messages

3. **`:CodeDiffInstall` command**
   - Manual installation/reinstallation
   - Defined in `lua/vscode-diff/commands.lua`
   - Registered in `plugin/vscode-diff.lua`

### Flow Diagram

```
Plugin Load
    ↓
diff.lua requires installer
    ↓
Check if library exists? → YES → Load with FFI ✓
    ↓ NO
installer.install()
    ↓
Detect OS (Linux/Windows/macOS)
    ↓
Detect Architecture (x64/arm64)
    ↓
Read VERSION file
    ↓
Build download URL:
https://github.com/esmuellert/vscode-diff.nvim/releases/download/v{VERSION}/libvscode_diff_{os}_{arch}_{version}.{ext}
    ↓
Download with: curl → wget → PowerShell
    ↓
Save as: libvscode_diff.{so|dylib|dll}
    ↓
Load with FFI ✓
```

## Platform Detection

### Operating System

Detected using `ffi.os`:
- `Windows` → `"windows"`
- `OSX` → `"macos"`
- Other → `"linux"`

### Architecture

Detected using `vim.loop.os_uname().machine`:
- `x86_64`, `amd64`, `x64` → `"x64"`
- `aarch64`, `arm64` → `"arm64"`

### Library Extensions

- Windows: `.dll`
- macOS: `.dylib`
- Linux: `.so`

## Version Management

The system reads the `VERSION` file in the plugin root to determine which library version to download. This ensures compatibility between the Lua code and C library.

**VERSION file format:**
```
0.8.0
```

**Download URL construction:**
```lua
local url = string.format(
  "https://github.com/esmuellert/vscode-diff.nvim/releases/download/v%s/%s",
  version,  -- e.g., "0.8.0"
  filename  -- e.g., "libvscode_diff_linux_x64_0.8.0.so"
)
```

## Download Methods

The installer tries multiple download methods in order:

1. **curl** (preferred)
   ```lua
   { "curl", "-fsSL", "-o", dest_path, url }
   ```

2. **wget** (fallback)
   ```lua
   { "wget", "-q", "-O", dest_path, url }
   ```

3. **PowerShell** (Windows fallback)
   ```lua
   {
     "powershell", "-NoProfile", "-Command",
     "Invoke-WebRequest -Uri 'url' -OutFile 'dest_path'"
   }
   ```

## Security Considerations

### Command Execution

- **Neovim 0.10+**: Uses `vim.system()` with argument arrays (no shell injection)
- **Older versions**: Falls back to `os.execute()` with proper shell escaping

### Escaping Strategy

For `os.execute()` fallback:
```lua
local escaped = arg:gsub("'", "'\\''")  -- Escape single quotes
local cmd = string.format("'%s'", escaped)
```

### HTTPS Only

All downloads are performed over HTTPS from GitHub's trusted domain:
```
https://github.com/esmuellert/vscode-diff.nvim/releases/download/...
```

## Error Handling

### Missing VERSION File

```
Failed to build download URL: Failed to read VERSION file at: /path/to/VERSION
```

**Solution:** Ensure VERSION file exists in plugin root.

### No Download Tool

```
No download tool found. Please install curl or wget.
```

**Solution:** Install curl or wget (or use PowerShell on Windows).

### Download Failure

```
Download failed: [error details]
```

**Troubleshooting:**
1. Check internet connectivity
2. Verify access to github.com
3. Check if release exists for your platform
4. Try manual install: `:CodeDiff install!`
5. Try building from source

## Automatic Updates

The installer automatically detects version mismatches using versioned library filenames:

### Version Management

1. **VERSION Loading**: The VERSION file is read once in `init.lua` and used as the single source of truth
2. **Versioned Filenames**: Libraries include version in filename (e.g., `libvscode_diff_0.8.0.so`)
3. **Version Detection**: Scans plugin root for `libvscode_diff_*.{so|dll|dylib}` files to detect installed version
4. **Auto-Update**: If versions don't match, downloads correct version and removes old file

**Update Flow:**
```
Plugin loads → Read VERSION from file (in init.lua)
  ↓
Scan plugin root for libvscode_diff_*.{ext} files
  ↓
Extract version from filename → Compare with VERSION
  ↓
Version mismatch? → Download new version → Remove old version file
  ↓
Version matches? → Use existing library
```

**Benefits:**
- No separate version marker file needed
- Version is explicit in the filename
- Easy to see installed version with `ls libvscode_diff*`
- Old versions automatically cleaned up during updates

This ensures users always have the correct library version without manual intervention when they update the plugin.

## Manual Installation Commands

### `:CodeDiff install`

Installs or updates the library to match the VERSION file.

**Usage:**
```vim
:CodeDiff install
```

### `:CodeDiff install!`

Forces reinstallation, even if library already exists and version matches.

**Usage:**
```vim
:CodeDiff install!
```

**Use cases:**
- Troubleshooting corrupted library
- Forcing a clean reinstall
- Testing installation process

## Supported Platforms

| OS | Architecture | Download Filename | Local Filename |
|----|--------------|-------------------|----------------|
| Linux | x64 | `libvscode_diff_linux_x64_0.8.0.so` | `libvscode_diff_0.8.0.so` |
| Linux | arm64 | `libvscode_diff_linux_arm64_0.8.0.so` | `libvscode_diff_0.8.0.so` |
| macOS | x64 | `libvscode_diff_macos_x64_0.8.0.dylib` | `libvscode_diff_0.8.0.dylib` |
| macOS | arm64 | `libvscode_diff_macos_arm64_0.8.0.dylib` | `libvscode_diff_0.8.0.dylib` |
| Windows | x64 | `libvscode_diff_windows_x64_0.8.0.dll` | `libvscode_diff_0.8.0.dll` |
| Windows | arm64 | `libvscode_diff_windows_arm64_0.8.0.dll` | `libvscode_diff_0.8.0.dll` |

**Note:** The download filename includes platform information (`{os}_{arch}`), but the local filename only includes the version. This allows FFI to load the library using just the version number.

## Testing

### Manual Testing

1. Remove existing library:
   ```bash
   rm libvscode_diff_*.so libvscode_diff_*.dll libvscode_diff_*.dylib
   ```

2. Load plugin (triggers auto-install):
   ```vim
   nvim
   :lua require('vscode-diff.diff')
   ```

3. Verify installation:
   ```bash
   ls -lh libvscode_diff_*
   # Should show: libvscode_diff_0.8.0.so (or .dll/.dylib)
   ```

4. Test version update:
   ```bash
   # Simulate old version
   touch libvscode_diff_0.7.0.so
   
   # Update VERSION file
   echo "0.8.0" > VERSION
   
   # Load plugin - should auto-update
   nvim -c "lua require('vscode-diff.diff')"
   
   # Verify old version removed
   ls -lh libvscode_diff_*
   # Should only show: libvscode_diff_0.8.0.so
   ```

### Automated Testing

See `/tmp/test_install.lua` and `/tmp/comprehensive_test.lua` for test scripts.

## Maintenance

### Updating Supported Versions

1. Update VERSION file:
   ```bash
   echo "0.9.0" > VERSION
   ```

2. Ensure GitHub release exists with all 6 platform binaries

3. Users will automatically download new version on next install

### Adding New Platforms

To add support for a new platform:

1. Update `detect_os()` or `detect_arch()` in `installer.lua`
2. Update `get_lib_ext()` if new extension needed
3. Ensure GitHub Actions builds for new platform
4. Update documentation

## Future Improvements

- [ ] Add checksum verification for downloaded files
- [ ] Cache downloads to avoid re-downloading on reinstall
- [ ] Add progress indicator for large downloads
- [ ] Support proxy configuration
- [ ] Add retry logic for failed downloads
- [ ] Implement version compatibility checking
