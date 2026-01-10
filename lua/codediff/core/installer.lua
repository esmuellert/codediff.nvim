-- Automatic installer for libvscode-diff binary
-- Downloads pre-built binaries from GitHub releases

local M = {}

-- Get the plugin root directory using shared path utility
local path_util = require("codediff.core.path")
local function get_plugin_root()
  return path_util.get_plugin_root()
end

-- Detect OS
local function detect_os()
  local ffi = require("ffi")
  if ffi.os == "Windows" then
    return "windows"
  elseif ffi.os == "OSX" then
    return "macos"
  else
    return "linux"
  end
end

-- Detect architecture
local function detect_arch()
  local ffi = require("ffi")

  -- Windows-specific detection using environment variables
  if ffi.os == "Windows" then
    local processor_arch = vim.fn.getenv("PROCESSOR_ARCHITECTURE")
    local processor_arch_w6432 = vim.fn.getenv("PROCESSOR_ARCHITEW6432")

    -- PROCESSOR_ARCHITEW6432 is set when running 32-bit process on 64-bit Windows
    local arch = processor_arch_w6432 ~= vim.NIL and processor_arch_w6432 or processor_arch

    if arch then
      arch = arch:lower()
      if arch:match("amd64") or arch:match("x64") then
        return "x64"
      elseif arch:match("arm64") then
        return "arm64"
      end
    end
  end

  -- Unix-like systems: use uname
  local uname = vim.loop.os_uname()
  local machine = uname.machine:lower()

  -- Handle different naming conventions
  if machine:match("x86_64") or machine:match("amd64") or machine:match("x64") then
    return "x64"
  elseif machine:match("aarch64") or machine:match("arm64") then
    return "arm64"
  end

  -- If we still can't detect, return error
  return nil, "Unsupported architecture: " .. (machine or "unknown")
end

-- Get library extension for current OS
local function get_lib_ext()
  local ffi = require("ffi")
  if ffi.os == "Windows" then
    return "dll"
  elseif ffi.os == "OSX" then
    return "dylib"
  else
    return "so"
  end
end

-- Get library filename with version
local function get_lib_filename(version)
  return string.format("libvscode_diff_%s.%s", version, get_lib_ext())
end

-- Get unversioned library filename (for manual builds)
local function get_unversioned_lib_filename()
  return "libvscode_diff." .. get_lib_ext()
end

-- Get the current VERSION from version.lua (single source of truth)
local function get_current_version()
  local version = require("codediff.version")
  return version.VERSION
end

-- Get installed library version by checking existing versioned files
-- Returns the latest version if multiple libraries exist
local function get_installed_version()
  local plugin_root = get_plugin_root()
  local ext = get_lib_ext()
  -- Escape the dot in the extension for pattern matching
  local pattern = "libvscode_diff_(.+)%." .. ext

  local versions = {}

  -- List files in plugin root and find all versioned libraries
  local handle = vim.loop.fs_scandir(plugin_root)
  if handle then
    while true do
      local name, type = vim.loop.fs_scandir_next(handle)
      if not name then
        break
      end

      if type == "file" then
        local version = name:match(pattern)
        if version then
          table.insert(versions, version)
        end
      end
    end
  end

  -- Return the latest version if any found
  if #versions > 0 then
    table.sort(versions, function(a, b)
      -- Parse semantic versions (e.g., "0.11.1")
      local a_parts = vim.split(a, "%.")
      local b_parts = vim.split(b, "%.")

      for i = 1, math.max(#a_parts, #b_parts) do
        local a_num = tonumber(a_parts[i]) or 0
        local b_num = tonumber(b_parts[i]) or 0
        if a_num ~= b_num then
          return a_num > b_num
        end
      end
      return false
    end)
    return versions[1]
  end

  return nil
end

-- Build download URL for GitHub release
local function build_download_url(os, arch, version)
  if not version or version == "" then
    return nil, nil, "VERSION is not available"
  end

  local ext = get_lib_ext()
  -- Download filename from GitHub (includes platform info)
  local download_filename = string.format("libvscode_diff_%s_%s_%s.%s", os, arch, version, ext)
  -- Local filename (only includes version)
  local local_filename = get_lib_filename(version)

  local url = string.format("https://github.com/esmuellert/vscode-diff.nvim/releases/download/v%s/%s", version, download_filename)

  return url, local_filename, nil
end

-- Check if a command exists
local function command_exists(cmd)
  local ffi = require("ffi")
  if ffi.os == "Windows" then
    -- On Windows, use 'where' command instead of 'which'
    local handle = io.popen("where " .. cmd .. " 2>nul")
    if handle then
      local result = handle:read("*a")
      handle:close()
      return result ~= ""
    end
    return false
  else
    local handle = io.popen("which " .. cmd .. " 2>/dev/null")
    if handle then
      local result = handle:read("*a")
      handle:close()
      return result ~= ""
    end
    return false
  end
end

-- Check if Neovim is running from Nix store
-- When nvim is from Nix, it uses Nix's own ld-linux which does NOT search
-- system library paths (/usr/lib, ldconfig cache). Libraries must be either:
-- 1. In RPATH/RUNPATH of the binary
-- 2. In Nix store paths configured in Nix's ld.so.cache
-- 3. Bundled alongside the .so (via $ORIGIN RPATH)
local function is_nvim_from_nix()
  local resolved = vim.fn.resolve(vim.v.progpath)
  return resolved:find("^/nix/store") ~= nil
end

-- Check if libgomp is available on the system
-- Uses ldconfig cache which matches what the native linker actually searches.
-- This is more reliable than ffi.load() which may find libraries via LD_LIBRARY_PATH
-- that aren't available when our binary loads (e.g., NixOS intermittent failures).
local function check_system_libgomp()
  local os_name = detect_os()

  -- Only check on Linux (macOS and Windows don't use libgomp)
  if os_name ~= "linux" then
    return true
  end

  -- Check if already bundled in plugin directory (RPATH $ORIGIN)
  local plugin_root = get_plugin_root()
  if vim.fn.filereadable(plugin_root .. "/libgomp.so.1") == 1 then
    return true
  end

  -- If nvim is from Nix store, system ldconfig is NOT used by Nix's ld-linux.
  -- We must bundle libgomp since Nix's linker won't find /usr/lib libraries.
  -- This handles both NixOS and non-NixOS systems using Nix Home Manager for nvim.
  if is_nvim_from_nix() then
    return false
  end

  -- Check ldconfig cache - this is what the native linker actually uses
  -- (excluding unreliable LD_LIBRARY_PATH which varies per session)
  local handle = io.popen("ldconfig -p 2>/dev/null | grep -q 'libgomp\\.so\\.1' && echo 'found'")
  if handle then
    local result = handle:read("*a")
    handle:close()
    if result:match("found") then
      return true
    end
  end

  -- Not found in ldconfig cache or ldconfig unavailable → bundle to be safe
  return false
end

-- Download file using curl, wget, or PowerShell
local function download_file(url, dest_path)
  local ffi = require("ffi")
  local cmd_args

  -- Try curl first (most common, best error handling)
  if command_exists("curl") then
    cmd_args = { "curl", "-fsSL", "-o", dest_path, url }
  elseif command_exists("wget") then
    cmd_args = { "wget", "-q", "-O", dest_path, url }
  elseif ffi.os == "Windows" then
    -- On Windows, try PowerShell Invoke-WebRequest
    cmd_args = {
      "powershell",
      "-NoProfile",
      "-Command",
      string.format("Invoke-WebRequest -Uri '%s' -OutFile '%s'", url, dest_path),
    }
  else
    return false, "No download tool found. Please install curl or wget."
  end

  -- Use vim.system if available (Neovim 0.10+), fallback to os.execute
  if vim.system then
    local result = vim.system(cmd_args, { text = true }):wait()
    if result.code == 0 then
      return true
    else
      local err_msg = result.stderr or result.stdout or "Unknown error"
      return false, string.format("Download failed: %s", err_msg)
    end
  else
    -- Fallback for older Neovim versions
    local cmd = table.concat(
      vim.tbl_map(function(arg)
        -- Basic escaping for shell
        return string.format("'%s'", arg:gsub("'", "'\\''"))
      end, cmd_args),
      " "
    )
    local exit_code = os.execute(cmd)
    if exit_code == true or exit_code == 0 then
      return true
    else
      return false, string.format("Download failed with exit code: %s", tostring(exit_code))
    end
  end
end

-- Install libgomp if needed
local function install_libgomp_if_needed(opts)
  local os_name = detect_os()

  -- Only needed on Linux
  if os_name ~= "linux" then
    return true
  end

  local plugin_root = get_plugin_root()
  local libgomp_path = plugin_root .. "/libgomp.so.1"

  -- Check if already bundled
  if vim.fn.filereadable(libgomp_path) == 1 then
    if not opts.silent then
      vim.notify("libgomp.so.1 already bundled", vim.log.levels.DEBUG)
    end
    return true
  end

  -- Check if system has libgomp
  if check_system_libgomp() then
    if not opts.silent then
      vim.notify("System libgomp.so.1 found, no need to bundle", vim.log.levels.DEBUG)
    end
    return true
  end

  -- Need to download libgomp
  if not opts.silent then
    vim.notify("System libgomp.so.1 not found, downloading...", vim.log.levels.INFO)
  end

  local arch, arch_err = detect_arch()
  if not arch then
    local msg = "Failed to detect architecture: " .. (arch_err or "unknown error")
    vim.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end

  local current_version = get_current_version()
  if not current_version then
    local msg = "Failed to read VERSION"
    vim.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end

  -- Build libgomp download URL
  local libgomp_filename = string.format("libgomp_linux_%s_%s.so.1", arch, current_version)
  local url = string.format("https://github.com/esmuellert/vscode-diff.nvim/releases/download/v%s/%s", current_version, libgomp_filename)

  if not opts.silent then
    vim.notify("Downloading libgomp from: " .. url, vim.log.levels.INFO)
  end

  -- Download to temporary location
  local temp_path = plugin_root .. "/libgomp.so.1.tmp"
  local success, err = download_file(url, temp_path)

  if not success then
    local msg = "Failed to download libgomp: " .. (err or "unknown error")
    vim.notify(msg, vim.log.levels.WARN)
    vim.notify("Plugin may not work without libgomp installed on your system", vim.log.levels.WARN)
    os.remove(temp_path)
    -- Don't fail the installation, just warn
    return true
  end

  -- Move to final location
  if vim.fn.filereadable(libgomp_path) == 1 then
    os.remove(libgomp_path)
  end

  local ok = os.rename(temp_path, libgomp_path)
  if not ok then
    local msg = "Failed to move libgomp to final location"
    vim.notify(msg, vim.log.levels.WARN)
    os.remove(temp_path)
    return true -- Don't fail installation
  end

  if not opts.silent then
    vim.notify("Successfully downloaded libgomp.so.1", vim.log.levels.INFO)
  end

  return true
end

-- Install the library
function M.install(opts)
  opts = opts or {}
  local force = opts.force or false

  local plugin_root = get_plugin_root()
  local current_version = get_current_version()

  if not current_version then
    local msg = "Failed to read VERSION"
    vim.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end

  local lib_filename = get_lib_filename(current_version)
  local lib_path = plugin_root .. "/" .. lib_filename

  -- Check if library already exists and is up-to-date
  if not force then
    -- Check for unversioned library (manual build) first
    local unversioned_lib = get_unversioned_lib_filename()
    local unversioned_path = plugin_root .. "/" .. unversioned_lib
    if vim.fn.filereadable(unversioned_path) == 1 then
      if not opts.silent then
        vim.notify("libvscode-diff (manual build) found at: " .. unversioned_path, vim.log.levels.INFO)
      end
      -- Still check and install libgomp if needed (e.g., Nix environment)
      install_libgomp_if_needed(opts)
      return true
    end

    local installed_version = get_installed_version()

    if installed_version and installed_version == current_version then
      if vim.fn.filereadable(lib_path) == 1 then
        if not opts.silent then
          vim.notify("libvscode-diff already installed at: " .. lib_path, vim.log.levels.INFO)
        end
        -- Still check and install libgomp if needed (e.g., Nix environment)
        install_libgomp_if_needed(opts)
        return true
      end
    elseif installed_version and not opts.silent then
      vim.notify(string.format("Updating libvscode-diff from v%s to v%s...", installed_version, current_version), vim.log.levels.INFO)

      -- Remove old version files
      local old_lib_filename = get_lib_filename(installed_version)
      local old_lib_path = plugin_root .. "/" .. old_lib_filename
      if vim.fn.filereadable(old_lib_path) == 1 then
        os.remove(old_lib_path)
      end
    end
  end

  -- Detect platform
  local os_name = detect_os()
  local arch, arch_err = detect_arch()

  if not arch then
    local msg = "Failed to detect architecture: " .. (arch_err or "unknown error")
    vim.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end

  if not opts.silent then
    vim.notify(string.format("Installing libvscode-diff v%s for %s %s...", current_version, os_name, arch), vim.log.levels.INFO)
  end

  -- Build download URL
  local url, local_filename, url_err = build_download_url(os_name, arch, current_version)

  if not url then
    local msg = "Failed to build download URL: " .. (url_err or "unknown error")
    vim.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end

  if not opts.silent then
    vim.notify("Downloading from: " .. url, vim.log.levels.INFO)
  end

  -- Download to temporary location first
  local temp_path = plugin_root .. "/" .. local_filename .. ".tmp"
  local success, err = download_file(url, temp_path)

  if not success then
    local msg = "Failed to download library: " .. (err or "unknown error")
    vim.notify(msg, vim.log.levels.ERROR)
    -- Clean up temp file if it exists
    os.remove(temp_path)
    return false, msg
  end

  -- Move to final location
  -- On Windows, os.rename fails if destination exists, so remove it first
  if vim.fn.filereadable(lib_path) == 1 then
    os.remove(lib_path)
  end

  local ok = os.rename(temp_path, lib_path)
  if not ok then
    local msg = "Failed to move library to final location: " .. lib_path
    vim.notify(msg, vim.log.levels.ERROR)
    os.remove(temp_path)
    return false, msg
  end

  if not opts.silent then
    vim.notify("Successfully installed libvscode-diff!", vim.log.levels.INFO)
  end

  -- Also check and install libgomp if needed
  install_libgomp_if_needed(opts)

  return true
end

-- Check if library is installed
function M.is_installed()
  local plugin_root = get_plugin_root()

  -- Check unversioned first (manual build)
  local unversioned_lib = get_unversioned_lib_filename()
  if vim.fn.filereadable(plugin_root .. "/" .. unversioned_lib) == 1 then
    return true
  end

  local current_version = get_current_version()
  if not current_version then
    return false
  end

  local lib_path = plugin_root .. "/" .. get_lib_filename(current_version)
  return vim.fn.filereadable(lib_path) == 1
end

-- Get library path
function M.get_lib_path()
  local plugin_root = get_plugin_root()

  -- Check unversioned first (manual build)
  local unversioned_lib = get_unversioned_lib_filename()
  local unversioned_path = plugin_root .. "/" .. unversioned_lib
  if vim.fn.filereadable(unversioned_path) == 1 then
    return unversioned_path
  end

  local current_version = get_current_version()
  if not current_version then
    return nil
  end

  return plugin_root .. "/" .. get_lib_filename(current_version)
end

-- Get the installed library version (by checking existing versioned files)
function M.get_installed_version()
  return get_installed_version()
end

-- Check if library needs update
function M.needs_update()
  -- Check libgomp first - if missing, we need to run installer regardless of main library status
  if not check_system_libgomp() then
    return true
  end

  local plugin_root = get_plugin_root()

  -- Check unversioned first - assume manual build is always up to date
  local unversioned_lib = get_unversioned_lib_filename()
  if vim.fn.filereadable(plugin_root .. "/" .. unversioned_lib) == 1 then
    return false
  end

  local current_version = get_current_version()
  if not current_version then
    return true
  end

  local installed_version = get_installed_version()

  if not installed_version then
    return true
  end

  return current_version ~= installed_version
end

return M
