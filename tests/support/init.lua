-- Cross-platform helpers shared by unit, integration and embedded UI tests.
local M = {}
M.project_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"):gsub("\\", "/")

function M.ensure_plugin_loaded()
  if not vim.g.loaded_codediff then
    local plugin_file = M.project_root .. "/plugin/codediff.lua"
    if vim.fn.filereadable(plugin_file) == 1 then
      dofile(plugin_file)
    end
  end
  -- Specs may clear autocmds between tests.
  require("codediff.core.virtual_file").setup()
end

M.is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
M.path_sep = M.is_windows and "\\" or "/"

function M.get_temp_dir()
  return M.is_windows and (vim.fn.getenv("TEMP") or "C:\\Windows\\Temp") or "/tmp"
end

function M.get_temp_path(filename)
  return M.get_temp_dir() .. M.path_sep .. filename
end

function M.create_temp_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return M.is_windows and dir:gsub("\\", "/") or dir
end

function M.git_cmd(dir, args)
  return require("tests.support.repository").git(dir, args)
end

-- A plugin-aware fixture: retire its sessions before removing directories that
-- an active native watcher (especially on Windows) still has open.
function M.create_temp_git_repo()
  local repo = require("tests.support.repository").new({ unborn = true })
  local remove = repo.cleanup
  repo.cleanup = function()
    local sessions = package.loaded["codediff.ui.lifecycle.session"]
    if sessions then
      local function belongs(path)
        if type(path) ~= "string" then
          return false
        end
        path = path:gsub("\\", "/")
        return path == repo.dir or path:sub(1, #repo.dir + 1) == repo.dir .. "/"
      end
      for tab, session in pairs(sessions.get_active_diffs()) do
        if belongs(session.git_root) or belongs(session.original and session.original.absolute) or belongs(session.modified and session.modified.absolute) then
          require("codediff.ui.lifecycle").cleanup(tab)
        end
      end
    end
    remove()
  end
  return repo
end

function M.wait_async(timeout_ms, condition_fn, interval_ms)
  timeout_ms = timeout_ms or 5000
  interval_ms = interval_ms or 50
  if condition_fn then
    return vim.wait(timeout_ms, condition_fn, interval_ms)
  end
  vim.wait(timeout_ms)
  return true
end

function M.wait_for_session_ready(tabpage, timeout_ms)
  local lifecycle = require("codediff.ui.lifecycle")
  return vim.wait(timeout_ms or 10000, function()
    local session = lifecycle.get_session(tabpage)
    if not session or not session.stored_diff_result then
      return false
    end
    local original, modified = lifecycle.get_buffers(tabpage)
    return original and modified and vim.api.nvim_buf_is_valid(original) and vim.api.nvim_buf_is_valid(modified)
  end, 100)
end

function M.wait_for_virtual_file_load(bufnr, timeout_ms)
  local loaded = false
  local group = vim.api.nvim_create_augroup("TestWaitVirtualFile", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeDiffVirtualFileLoaded",
    callback = function(event)
      if event.data and event.data.buf == bufnr then
        loaded = true
      end
    end,
  })
  local ok = vim.wait(timeout_ms or 5000, function()
    return loaded
  end, 50)
  pcall(vim.api.nvim_del_augroup_by_id, group)
  return ok
end

function M.wait_for_buffer_content(bufnr, expected, timeout_ms)
  return vim.wait(timeout_ms or 5000, function()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return false
    end
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"):find(expected, 1, true) ~= nil
  end, 50)
end

-- Re-fetch the pane's buffer each time: updates can replace revision buffers.
function M.wait_for_modified_content(tabpage, expected, timeout_ms)
  local lifecycle = require("codediff.ui.lifecycle")
  return vim.wait(timeout_ms or 5000, function()
    local _, buf = lifecycle.get_buffers(tabpage)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return false
    end
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find(expected, 1, true) ~= nil
  end, 50)
end

function M.get_buffer_content(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

function M.get_buffer_lines(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

function M.normalize_path(path)
  if not path then
    return nil
  end
  local normalized = vim.fn.fnamemodify(path, ":p"):gsub("[/\\]$", ""):gsub("\\", "/")
  return normalized
end

function M.close_extra_tabs()
  while vim.fn.tabpagenr("$") > 1 do
    vim.cmd("tabclose")
  end
end

function M.find_window_by_filetype(filetype)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == filetype then
      return win, buf
    end
  end
  return nil, nil
end

function M.wait_for_explorer(timeout_ms)
  return vim.wait(timeout_ms or 5000, function()
    return M.find_window_by_filetype("codediff-explorer") ~= nil
  end, 50)
end

function M.wait_for_diff_ready(timeout_ms)
  local lifecycle = require("codediff.ui.lifecycle")
  local tabpage = vim.api.nvim_get_current_tabpage()
  return vim.wait(timeout_ms or 10000, function()
    local session = lifecycle.get_session(tabpage)
    if not session or not session.stored_diff_result then
      return false
    end
    local original, modified = lifecycle.get_buffers(tabpage)
    return original and modified and vim.api.nvim_buf_is_valid(original) and vim.api.nvim_buf_is_valid(modified)
  end, 100)
end

function M.assert_contains(value, text, message)
  assert(value and value:find(text, 1, true), message or string.format("Expected '%s' to contain '%s'", value or "nil", text))
end

return M
