-- FFI wrapper for compute_diff C library
-- Provides LinesDiff data structure from C to Lua

local M = {}
local ffi = require("ffi")

-- Get VERSION from version.lua (single source of truth)
local version = require("codediff.version")
local VERSION = version.VERSION

-- Load the C library with automatic installation
local lib_ext
if ffi.os == "Windows" then
  lib_ext = "dll"
elseif ffi.os == "OSX" then
  lib_ext = "dylib"
else
  lib_ext = "so"
end

-- Build versioned library filename
local path_util = require("codediff.core.path")
local plugin_root = path_util.get_plugin_root()
local lib_name = string.format("libvscode_diff_%s.%s", VERSION, lib_ext)
local lib_path = plugin_root .. "/" .. lib_name

-- Check if library exists or needs update, if so, install/update it
-- Skip auto-installation if explicitly disabled (e.g., in tests where library is already built)
local installer = require("codediff.core.installer")
if not vim.env.VSCODE_DIFF_NO_AUTO_INSTALL and installer.needs_update() then
  local success, err = installer.install({ silent = false })
  if not success then
    error(
      string.format(
        "libvscode-diff not found and automatic installation failed: %s\n"
          .. "Troubleshooting:\n"
          .. "1. Check that curl or wget is installed\n"
          .. "2. Verify internet connectivity to github.com\n"
          .. "3. Try manual install: :CodeDiff install!\n"
          .. "4. Or build from source: run 'make' (Unix) or 'build.cmd' (Windows)\n"
          .. "5. Download manually from: https://github.com/esmuellert/vscode-diff.nvim/releases",
        err or "unknown error"
      )
    )
  end
end

-- Try to load the library - fall back to unversioned name for local builds
local lib
local load_ok, load_err = pcall(function()
  lib = ffi.load(lib_path)
end)

if not load_ok then
  -- Try fallback to unversioned library (for local builds and tests)
  local fallback_lib_name = "libvscode_diff." .. lib_ext
  local fallback_path = plugin_root .. "/" .. fallback_lib_name
  if vim.fn.filereadable(fallback_path) == 1 then
    lib = ffi.load(fallback_path)
  else
    error(load_err)
  end
end

-- FFI type definitions matching C types.h
ffi.cdef([[
  // Basic range types
  typedef struct {
    int start_line;  // 1-based, inclusive
    int end_line;    // 1-based, EXCLUSIVE
  } LineRange;

  typedef struct {
    int start_line;  // 1-based
    int start_col;   // 1-based, inclusive
    int end_line;    // 1-based
    int end_col;     // 1-based, EXCLUSIVE
  } CharRange;

  // Mapping types
  typedef struct {
    CharRange original;
    CharRange modified;
  } RangeMapping;

  typedef struct {
    LineRange original;
    LineRange modified;
    RangeMapping* inner_changes;
    int inner_change_count;
  } DetailedLineRangeMapping;

  typedef struct {
    DetailedLineRangeMapping* mappings;
    int count;
    int capacity;
  } DetailedLineRangeMappingArray;

  typedef struct {
    LineRange original;
    LineRange modified;
  } MovedText;

  typedef struct {
    MovedText* moves;
    int count;
    int capacity;
  } MovedTextArray;

  // Main diff result
  typedef struct {
    DetailedLineRangeMappingArray changes;
    MovedTextArray moves;
    bool hit_timeout;
  } LinesDiff;

  // Options
  typedef struct {
    bool ignore_trim_whitespace;
    int max_computation_time_ms;
    bool compute_moves;
    bool extend_to_subwords;
  } DiffOptions;

  // API functions
  LinesDiff* compute_diff(
    const char** original_lines,
    int original_count,
    const char** modified_lines,
    int modified_count,
    const DiffOptions* options
  );

  void free_lines_diff(LinesDiff* diff);
  const char* get_version(void);
]])

---@class DiffOptions
---@field ignore_trim_whitespace boolean
---@field max_computation_time_ms integer
---@field compute_moves boolean
---@field extend_to_subwords boolean

-- Convert Lua string array to C string array
local function lua_to_c_strings(lines)
  local count = #lines
  local c_array = ffi.new("const char*[?]", count)

  for i = 1, count do
    c_array[i - 1] = lines[i]
  end

  return c_array, count
end

-- Convert C CharRange to Lua table
local function char_range_to_lua(c_range)
  return {
    start_line = c_range.start_line,
    start_col = c_range.start_col,
    end_line = c_range.end_line,
    end_col = c_range.end_col,
  }
end

-- Convert C LineRange to Lua table
local function line_range_to_lua(c_range)
  return {
    start_line = c_range.start_line,
    end_line = c_range.end_line,
  }
end

-- Convert C RangeMapping to Lua table
local function range_mapping_to_lua(c_mapping)
  return {
    original = char_range_to_lua(c_mapping.original),
    modified = char_range_to_lua(c_mapping.modified),
  }
end

-- Convert C DetailedLineRangeMapping to Lua table
local function detailed_mapping_to_lua(c_mapping)
  local inner_changes = {}

  if c_mapping.inner_changes ~= nil then
    for i = 0, c_mapping.inner_change_count - 1 do
      table.insert(inner_changes, range_mapping_to_lua(c_mapping.inner_changes[i]))
    end
  end

  return {
    original = line_range_to_lua(c_mapping.original),
    modified = line_range_to_lua(c_mapping.modified),
    inner_changes = inner_changes,
  }
end

-- Convert C MovedText to Lua table
local function moved_text_to_lua(c_moved)
  return {
    original = line_range_to_lua(c_moved.original),
    modified = line_range_to_lua(c_moved.modified),
  }
end

-- Convert C LinesDiff to Lua table
local function lines_diff_to_lua(c_diff)
  if c_diff == nil then
    return nil
  end

  local changes = {}
  for i = 0, c_diff.changes.count - 1 do
    table.insert(changes, detailed_mapping_to_lua(c_diff.changes.mappings[i]))
  end

  local moves = {}
  for i = 0, c_diff.moves.count - 1 do
    table.insert(moves, moved_text_to_lua(c_diff.moves.moves[i]))
  end

  return {
    changes = changes,
    moves = moves,
    hit_timeout = c_diff.hit_timeout,
  }
end

-- Main API: Compute diff between two sets of lines
-- Returns Lua table representation of LinesDiff
function M.compute_diff(original_lines, modified_lines, options)
  options = options or {}

  -- Convert Lua lines to C arrays
  local c_orig, orig_count = lua_to_c_strings(original_lines)
  local c_mod, mod_count = lua_to_c_strings(modified_lines)

  -- Create options struct
  ---@type DiffOptions
  ---@diagnostic disable-next-line: assign-type-mismatch
  local c_options = ffi.new("DiffOptions")
  c_options.ignore_trim_whitespace = options.ignore_trim_whitespace or false
  c_options.max_computation_time_ms = options.max_computation_time_ms or 5000
  c_options.compute_moves = options.compute_moves or false
  c_options.extend_to_subwords = options.extend_to_subwords or false

  -- Call C function
  local c_diff = lib.compute_diff(c_orig, orig_count, c_mod, mod_count, c_options)

  if c_diff == nil then
    error("compute_diff returned NULL")
  end

  -- Convert to Lua table
  local lua_diff = lines_diff_to_lua(c_diff)

  -- Free C memory
  lib.free_lines_diff(c_diff)

  return lua_diff
end

-- Get library version
function M.get_version()
  return ffi.string(lib.get_version())
end

return M
