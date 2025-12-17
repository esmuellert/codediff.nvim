-- Test helpers for vscode-diff tests
-- Provides cross-platform utilities and common test patterns

local M = {}

-- Ensure the plugin is loaded
-- This is needed because PlenaryBustedFile spawns a subprocess that may not have loaded our plugin
function M.ensure_plugin_loaded()
  if not vim.g.loaded_vscode_diff then
    local plugin_file = vim.fn.getcwd() .. '/plugin/vscode-diff.lua'
    if vim.fn.filereadable(plugin_file) == 1 then
      dofile(plugin_file)
    end
  end
end

-- Detect if running on Windows
M.is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

-- Get path separator for current OS
M.path_sep = M.is_windows and "\\" or "/"

-- Get temp directory path
function M.get_temp_dir()
  if M.is_windows then
    return vim.fn.getenv("TEMP") or "C:\\Windows\\Temp"
  else
    return "/tmp"
  end
end

-- Get a temp file path with given filename
function M.get_temp_path(filename)
  return M.get_temp_dir() .. M.path_sep .. filename
end

-- Create a unique temp directory and return its path
function M.create_temp_dir()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  -- On Windows, normalize to forward slashes for consistency
  if M.is_windows then
    temp_dir = temp_dir:gsub("\\", "/")
  end
  return temp_dir
end

-- Run git command in a specific directory (cross-platform)
-- Uses git -C <dir> which works on both Windows and Unix
function M.git_cmd(dir, args)
  local safe_dir
  if M.is_windows then
    -- On Windows, use double quotes for paths with spaces
    safe_dir = '"' .. dir .. '"'
  else
    safe_dir = vim.fn.shellescape(dir)
  end
  local cmd = string.format('git -C %s %s', safe_dir, args)
  local output = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error
  return output, exit_code
end

-- Initialize a temp git repository with basic config
-- Returns: { dir = path, cleanup = function }
function M.create_temp_git_repo()
  local temp_dir = M.create_temp_dir()
  
  M.git_cmd(temp_dir, "init")
  M.git_cmd(temp_dir, "config user.email 'test@test.com'")
  M.git_cmd(temp_dir, "config user.name 'Test'")
  -- Set default branch name to avoid warnings
  M.git_cmd(temp_dir, "branch -m main")
  
  -- Get the canonical path from git to match what get_git_root() returns
  -- On Windows: avoids 8.3 short name vs long name mismatches
  -- On macOS: avoids /var vs /private/var symlink issues
  local output = M.git_cmd(temp_dir, "rev-parse --show-toplevel")
  if output then
    local canonical = vim.trim(output)
    if canonical and canonical ~= '' then
      temp_dir = canonical
    end
  end
  
  return {
    dir = temp_dir,
    -- Helper to run git in this repo
    git = function(args)
      return M.git_cmd(temp_dir, args)
    end,
    -- Helper to create a file in this repo
    write_file = function(rel_path, lines)
      local full_path = temp_dir .. "/" .. rel_path
      -- Ensure parent directory exists
      local parent = vim.fn.fnamemodify(full_path, ":h")
      vim.fn.mkdir(parent, "p")
      vim.fn.writefile(lines, full_path)
      return full_path
    end,
    -- Helper to get full path
    path = function(rel_path)
      return temp_dir .. "/" .. rel_path
    end,
    -- Cleanup function
    cleanup = function()
      vim.fn.delete(temp_dir, "rf")
    end
  }
end

-- Wait for an async operation to complete
-- This processes the event loop properly for vim.system callbacks
-- @param timeout_ms: Maximum time to wait
-- @param condition_fn: Function that returns true when done (optional)
-- @param interval_ms: Check interval (default 50ms)
-- @return boolean: true if condition was met, false if timed out
function M.wait_async(timeout_ms, condition_fn, interval_ms)
  timeout_ms = timeout_ms or 5000
  interval_ms = interval_ms or 50
  
  if condition_fn then
    return vim.wait(timeout_ms, condition_fn, interval_ms)
  else
    -- Fixed wait - just process events for the duration
    vim.wait(timeout_ms)
    return true
  end
end

-- Wait for a lifecycle session to be fully ready
-- This handles the async virtual file loading
-- @param tabpage: The tabpage number
-- @param timeout_ms: Maximum time to wait (default 10000ms for CI)
-- @return boolean: true if session is ready
function M.wait_for_session_ready(tabpage, timeout_ms)
  timeout_ms = timeout_ms or 10000
  local lifecycle = require('vscode-diff.render.lifecycle')
  
  return vim.wait(timeout_ms, function()
    local session = lifecycle.get_session(tabpage)
    if not session then return false end
    if not session.stored_diff_result then return false end
    
    local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
    if not orig_buf or not mod_buf then return false end
    
    return vim.api.nvim_buf_is_valid(orig_buf) and vim.api.nvim_buf_is_valid(mod_buf)
  end, 100)
end

-- Wait for a virtual file load event to fire for the specified buffer
-- This is useful when calling view.update with mutable revisions like :0
-- @param bufnr: The buffer number to wait for
-- @param timeout_ms: Maximum time to wait (default 5000ms)
-- @return boolean: true if event fired
function M.wait_for_virtual_file_load(bufnr, timeout_ms)
  timeout_ms = timeout_ms or 5000
  local loaded = false
  
  local group = vim.api.nvim_create_augroup('TestWaitVirtualFile', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'VscodeDiffVirtualFileLoaded',
    callback = function(event)
      if event.data and event.data.buf == bufnr then
        loaded = true
      end
    end,
  })
  
  local ok = vim.wait(timeout_ms, function() return loaded end, 50)
  pcall(vim.api.nvim_del_augroup_by_id, group)
  return ok
end

-- Wait for buffer content to contain expected text
-- @param bufnr: The buffer number
-- @param expected: Text that should be in the buffer
-- @param timeout_ms: Maximum time to wait (default 5000ms)
-- @return boolean: true if content found
function M.wait_for_buffer_content(bufnr, expected, timeout_ms)
  timeout_ms = timeout_ms or 5000
  return vim.wait(timeout_ms, function()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return false
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local content = table.concat(lines, '\n')
    return content:find(expected, 1, true) ~= nil
  end, 50)
end

-- Get buffer content as a single string
function M.get_buffer_content(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n")
end

-- Get buffer content as lines table
function M.get_buffer_lines(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- Normalize a path for comparison (forward slashes, no trailing slash)
function M.normalize_path(path)
  if not path then return nil end
  -- Convert to absolute
  path = vim.fn.fnamemodify(path, ':p')
  -- Remove trailing slashes
  path = path:gsub('[/\\]$', '')
  -- Normalize to forward slashes
  path = path:gsub('\\', '/')
  return path
end

-- Close all tabs except the first one (cleanup helper)
function M.close_extra_tabs()
  while vim.fn.tabpagenr('$') > 1 do
    vim.cmd('tabclose')
  end
end

-- Assert that a string contains a substring
function M.assert_contains(str, substr, msg)
  local found = str and str:find(substr, 1, true) ~= nil
  assert(found, msg or string.format("Expected '%s' to contain '%s'", str or "nil", substr))
end

return M
