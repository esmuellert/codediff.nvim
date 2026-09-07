local M = {}

local common = require("codediff.core.installer.common")
local path_util = require("codediff.core.path")
local uv = vim.uv or vim.loop

local VERSION = "0.23.2"
local RELEASE_BASE = "https://github.com/esmuellert/codediff/releases/download/v" .. VERSION
local pending_callbacks = {}
local installing = false

local function join(...)
  return table.concat({ ... }, "/")
end

local function executable_name(versioned)
  local version = versioned and "_" .. VERSION or ""
  local extension = require("ffi").os == "Windows" and ".exe" or ""
  return "codediff-watcher" .. version .. extension
end

local function install_root()
  return path_util.get_plugin_root()
end

local function executable_path(versioned)
  return join(install_root(), executable_name(versioned))
end

local function finish(path, err)
  installing = false
  if path then
    common.notify_success("codediff-watcher")
  elseif err then
    vim.notify("Failed to install codediff-watcher; using polling fallback: " .. err, vim.log.levels.WARN)
  end
  local callbacks = pending_callbacks
  pending_callbacks = {}
  for _, callback in ipairs(callbacks) do
    pcall(callback, path, err)
  end
end

local function detect_platform()
  local os_name = common.detect_os()
  if os_name == "android" then
    return nil, nil, "codediff-watcher has no Android release"
  end
  local arch, arch_err = common.detect_arch()
  if not arch then
    return nil, nil, arch_err
  end
  return os_name, arch
end

local function extract_command(archive, destination, os_name)
  if os_name == "windows" then
    local escaped_archive = archive:gsub("'", "''")
    local escaped_destination = destination:gsub("'", "''")
    return {
      "powershell",
      "-NoProfile",
      "-Command",
      string.format("Expand-Archive -LiteralPath '%s' -DestinationPath '%s' -Force", escaped_archive, escaped_destination),
    }
  end
  return { "tar", "-xzf", archive, "-C", destination }
end

local function install_watcher()
  local os_name, arch, platform_err = detect_platform()
  if not os_name then
    return nil, platform_err
  end

  local extension = os_name == "windows" and ".zip" or ".tar.gz"
  local archive_executable = executable_name(false)
  local archive_name = string.format("codediff-watcher-%s-%s-%s%s", VERSION, os_name, arch, extension)
  local install_dir = install_root()
  local binary_path = executable_path(true)
  local nonce = tostring(uv.hrtime()):gsub("%D", "")
  local temporary_name = string.format(".codediff-watcher-download-%d-%s%s", uv.os_getpid(), nonce, extension)
  local archive_path = join(install_dir, temporary_name)
  local staging_dir = join(install_dir, ".codediff-watcher-extract-" .. uv.os_getpid() .. "-" .. nonce)
  local staged_binary = join(staging_dir, archive_executable)
  vim.fn.mkdir(staging_dir, "p")

  local function cleanup()
    os.remove(archive_path)
    vim.fn.delete(staging_dir, "rf")
  end

  local url = RELEASE_BASE .. "/" .. archive_name
  local downloaded, download_error = common.download({
    name = "codediff-watcher",
    version = VERSION,
    os = os_name,
    arch = arch,
    url = url,
    destination = archive_path,
  })
  if not downloaded then
    cleanup()
    return nil, "failed to download watcher archive: " .. download_error
  end

  local extracted, extract_error = common.run(extract_command(archive_path, staging_dir, os_name))
  os.remove(archive_path)
  if not extracted then
    cleanup()
    return nil, "failed to extract watcher archive: " .. vim.trim(extract_error)
  end
  if vim.fn.filereadable(staged_binary) == 0 then
    cleanup()
    return nil, "watcher archive did not contain " .. archive_executable
  end
  if os_name ~= "windows" then
    uv.fs_chmod(staged_binary, 493)
  end

  local renamed, rename_error = uv.fs_rename(staged_binary, binary_path)
  cleanup()
  if renamed or vim.fn.filereadable(binary_path) == 1 then
    return binary_path
  end
  return nil, "failed to install codediff-watcher: " .. tostring(rename_error)
end

function M.ensure(callback)
  local override = vim.env.CODEDIFF_WATCHER_PATH
  if override and override ~= "" and vim.fn.filereadable(override) == 1 then
    callback(vim.fn.fnamemodify(override, ":p"))
    return
  end

  local manual = executable_path(false)
  if vim.fn.filereadable(manual) == 1 then
    callback(manual)
    return
  end

  local installed = executable_path(true)
  if vim.fn.filereadable(installed) == 1 then
    callback(installed)
    return
  end

  local from_path = vim.fn.exepath("codediff-watcher")
  if from_path ~= "" then
    callback(from_path)
    return
  end

  if vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL == "1" then
    callback(nil, "automatic watcher installation is disabled")
    return
  end

  pending_callbacks[#pending_callbacks + 1] = callback
  if installing then
    return
  end
  installing = true
  finish(install_watcher())
end

M.VERSION = VERSION

return M
