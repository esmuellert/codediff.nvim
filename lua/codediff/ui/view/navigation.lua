-- Navigation module - provides public API for navigating hunks and files
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")
local cursor_util = require("codediff.ui.view.cursor")

-- Hop to the next/previous file in the explorer's list.
--
-- The cursor will land on the first or last hunk of the new file once the
-- file finishes loading; we communicate that wish by stashing
-- `session.pending_cursor_landing` on the current session, which the
-- diff-render completion path in view/render.lua reads and clears
-- synchronously (no autocmds, no async tracking needed here).
--
-- Returns true if a hop was performed.
local function hop_to_adjacent_file(direction)
  local tabpage = vim.api.nvim_get_current_tabpage()
  local panel_obj = lifecycle.get_panel_view(tabpage)
  if not panel_obj then
    -- Cross-file cycling only makes sense in explorer/history mode.
    return false
  end

  local session = lifecycle.get_session(tabpage)
  if session then
    -- "next" → land on first hunk of the next file (the natural forward walk)
    -- "prev" → land on last hunk of the previous file (the natural backward walk)
    session.pending_cursor_landing = direction == "next" and "first" or "last"
  end

  if direction == "next" then
    return M.next_file()
  else
    return M.prev_file()
  end
end

-- Move focus to the modified window if the cursor isn't in a diff pane.
-- Returns whether to use original-side line numbers, or nil if there's no diff window.
local function focus_diff_pane(session)
  local buf = vim.api.nvim_get_current_buf()
  if buf ~= session.original_bufnr and buf ~= session.modified_bufnr and buf ~= session.result_bufnr then
    local win = session.modified_win
    if not (win and vim.api.nvim_win_is_valid(win)) then
      return nil
    end
    vim.api.nvim_set_current_win(win)
    buf = vim.api.nvim_get_current_buf()
  end
  -- Inline only shows the modified side; the result buffer (conflict mode) uses modified-side lines
  return session.layout ~= "inline" and buf == session.original_bufnr
end

-- Navigate to next hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.next_hunk()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session or not session.stored_diff_result then
    return false
  end

  local diff_result = session.stored_diff_result
  if not diff_result.changes or #diff_result.changes == 0 then
    return config.options.diff.cycle_hunks_across_files and hop_to_adjacent_file("next")
  end

  local is_original = focus_diff_pane(session)
  if is_original == nil then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]

  -- Find next hunk after current line
  for i, mapping in ipairs(diff_result.changes) do
    local target_line = cursor_util.clamp_line(vim.api.nvim_get_current_buf(), (is_original and mapping.original or mapping.modified).start_line)
    if target_line > current_line then
      pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
      vim.cmd("normal! zz")
      vim.api.nvim_echo({ { string.format("Hunk %d of %d", i, #diff_result.changes), "None" } }, false, {})
      return true
    end
  end

  -- At the end of the file's hunks. Try to hop to the next file before
  -- falling back to within-file wrap.
  if config.options.diff.cycle_hunks_across_files and hop_to_adjacent_file("next") then
    return true
  end

  -- Wrap around to first hunk (if cycling enabled)
  if config.options.diff.cycle_next_hunk then
    local first_hunk = diff_result.changes[1]
    local target_line = cursor_util.clamp_line(vim.api.nvim_get_current_buf(), (is_original and first_hunk.original or first_hunk.modified).start_line)
    pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
    vim.cmd("normal! zz")
    vim.api.nvim_echo({ { string.format("Hunk 1 of %d", #diff_result.changes), "None" } }, false, {})
    return true
  else
    vim.api.nvim_echo({ { string.format("Last hunk (%d of %d)", #diff_result.changes, #diff_result.changes), "WarningMsg" } }, false, {})
    return false
  end
end

-- Navigate to previous hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.prev_hunk()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session or not session.stored_diff_result then
    return false
  end

  local diff_result = session.stored_diff_result
  if not diff_result.changes or #diff_result.changes == 0 then
    return config.options.diff.cycle_hunks_across_files and hop_to_adjacent_file("prev")
  end

  local is_original = focus_diff_pane(session)
  if is_original == nil then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]

  -- Find previous hunk before current line (search backwards)
  for i = #diff_result.changes, 1, -1 do
    local mapping = diff_result.changes[i]
    local target_line = cursor_util.clamp_line(vim.api.nvim_get_current_buf(), (is_original and mapping.original or mapping.modified).start_line)
    if target_line < current_line then
      pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
      vim.cmd("normal! zz")
      vim.api.nvim_echo({ { string.format("Hunk %d of %d", i, #diff_result.changes), "None" } }, false, {})
      return true
    end
  end

  -- Before the first hunk in this file. Try to hop to the previous file.
  if config.options.diff.cycle_hunks_across_files and hop_to_adjacent_file("prev") then
    return true
  end

  -- Wrap around to last hunk (if cycling enabled)
  if config.options.diff.cycle_next_hunk then
    local last_hunk = diff_result.changes[#diff_result.changes]
    local target_line = cursor_util.clamp_line(vim.api.nvim_get_current_buf(), (is_original and last_hunk.original or last_hunk.modified).start_line)
    pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
    vim.cmd("normal! zz")
    vim.api.nvim_echo({ { string.format("Hunk %d of %d", #diff_result.changes, #diff_result.changes), "None" } }, false, {})
    return true
  else
    vim.api.nvim_echo({ { string.format("First hunk (1 of %d)", #diff_result.changes), "WarningMsg" } }, false, {})
    return false
  end
end

-- Navigate to next file in explorer/history mode
-- In single-file history mode, navigates to next commit instead
-- Returns true if navigation succeeded, false otherwise
function M.next_file()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local panel = lifecycle.get_panel(tabpage)

  if not (panel and panel.view) then
    return false
  end

  local panel_obj = panel.view
  local is_history_mode = panel.name == "history"

  if is_history_mode then
    local history = require("codediff.ui.history")
    if panel_obj.is_single_file_mode then
      history.navigate_next_commit(panel_obj)
    else
      history.navigate_next(panel_obj)
    end
  else
    local explorer = require("codediff.ui.explorer")
    explorer.navigate_next(panel_obj)
  end

  return true
end

-- Navigate to previous file in explorer/history mode
-- In single-file history mode, navigates to previous commit instead
-- Returns true if navigation succeeded, false otherwise
function M.prev_file()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local panel = lifecycle.get_panel(tabpage)

  if not (panel and panel.view) then
    return false
  end

  local panel_obj = panel.view
  local is_history_mode = panel.name == "history"

  if is_history_mode then
    local history = require("codediff.ui.history")
    if panel_obj.is_single_file_mode then
      history.navigate_prev_commit(panel_obj)
    else
      history.navigate_prev(panel_obj)
    end
  else
    local explorer = require("codediff.ui.explorer")
    explorer.navigate_prev(panel_obj)
  end

  return true
end

return M
