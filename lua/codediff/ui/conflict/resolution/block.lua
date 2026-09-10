-- Resolution commands for the conflict block under the cursor.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local auto_refresh = require("codediff.ui.auto_refresh")
local tracking = require("codediff.ui.conflict.tracking")
local gutter = require("codediff.ui.conflict.gutter")
local apply_to_result = require("codediff.ui.conflict.resolution.replace").apply_to_result
local combine = require("codediff.ui.conflict.resolution.combine")
local smart_combine_inputs = combine.smart_combine_inputs
local dumb_combine_inputs = combine.dumb_combine_inputs

--- Accept incoming (left/input1) side for the conflict under cursor
--- @param tabpage number
--- @return boolean success
function M.accept_incoming(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[codediff] No active session", vim.log.levels.WARN)
    return false
  end

  if not session.conflict_blocks or #session.conflict_blocks == 0 then
    vim.notify("[codediff] No conflicts in this session", vim.log.levels.WARN)
    return false
  end

  -- Determine which buffer cursor is in and find the conflict
  local current_buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local side = nil

  if current_buf == session.original_bufnr then
    side = "left"
  elseif current_buf == session.modified_bufnr then
    side = "right"
  else
    vim.notify("[codediff] Cursor not in diff buffer", vim.log.levels.WARN)
    return false
  end

  local block = tracking.find_conflict_at_cursor(session, cursor_line, side, false)
  if not block then
    vim.notify("[codediff] No active conflict at cursor position", vim.log.levels.INFO)
    return false
  end

  -- Get incoming (left) content
  local incoming_lines = tracking.get_lines_for_range(session.original_bufnr, block.output1_range.start_line, block.output1_range.end_line)

  -- Apply to result
  local result_bufnr = session.result_bufnr
  local base_lines = session.result_base_lines
  if not result_bufnr or not base_lines then
    vim.notify("[codediff] No result buffer or base lines", vim.log.levels.ERROR)
    return false
  end

  apply_to_result(result_bufnr, block, incoming_lines, base_lines)
  gutter.refresh(session)
  auto_refresh.refresh_result_now(result_bufnr)
  return true
end

--- Accept current (right/input2) side for the conflict under cursor
--- @param tabpage number
--- @return boolean success
function M.accept_current(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[codediff] No active session", vim.log.levels.WARN)
    return false
  end

  if not session.conflict_blocks or #session.conflict_blocks == 0 then
    vim.notify("[codediff] No conflicts in this session", vim.log.levels.WARN)
    return false
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local side = nil

  if current_buf == session.original_bufnr then
    side = "left"
  elseif current_buf == session.modified_bufnr then
    side = "right"
  else
    vim.notify("[codediff] Cursor not in diff buffer", vim.log.levels.WARN)
    return false
  end

  local block = tracking.find_conflict_at_cursor(session, cursor_line, side, false)
  if not block then
    vim.notify("[codediff] No active conflict at cursor position", vim.log.levels.INFO)
    return false
  end

  -- Get current (right) content
  local current_lines = tracking.get_lines_for_range(session.modified_bufnr, block.output2_range.start_line, block.output2_range.end_line)

  local result_bufnr = session.result_bufnr
  local base_lines = session.result_base_lines
  if not result_bufnr or not base_lines then
    vim.notify("[codediff] No result buffer or base lines", vim.log.levels.ERROR)
    return false
  end

  apply_to_result(result_bufnr, block, current_lines, base_lines)
  gutter.refresh(session)
  auto_refresh.refresh_result_now(result_bufnr)
  return true
end

--- Accept both sides (smart combination like VSCode) for the conflict under cursor
--- @param tabpage number
--- @return boolean success
function M.accept_both(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[codediff] No active session", vim.log.levels.WARN)
    return false
  end

  if not session.conflict_blocks or #session.conflict_blocks == 0 then
    vim.notify("[codediff] No conflicts in this session", vim.log.levels.WARN)
    return false
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local side = nil

  if current_buf == session.original_bufnr then
    side = "left"
  elseif current_buf == session.modified_bufnr then
    side = "right"
  else
    vim.notify("[codediff] Cursor not in diff buffer", vim.log.levels.WARN)
    return false
  end

  local block = tracking.find_conflict_at_cursor(session, cursor_line, side, false)
  if not block then
    vim.notify("[codediff] No active conflict at cursor position", vim.log.levels.INFO)
    return false
  end

  local result_bufnr = session.result_bufnr
  local base_lines = session.result_base_lines
  if not result_bufnr or not base_lines then
    vim.notify("[codediff] No result buffer or base lines", vim.log.levels.ERROR)
    return false
  end

  -- Determine first_input based on which side the cursor is on (matches VSCode behavior)
  -- If cursor is on left (incoming), incoming comes first
  -- If cursor is on right (current), current comes first
  local first_input = (side == "left") and 1 or 2

  -- Try smart combination first (like VSCode's "Accept Combination")
  local combined = smart_combine_inputs(session, block, first_input)

  if not combined then
    -- Fallback to dumb combination (concatenate)
    local incoming_lines = tracking.get_lines_for_range(session.original_bufnr, block.output1_range.start_line, block.output1_range.end_line)
    local current_lines = tracking.get_lines_for_range(session.modified_bufnr, block.output2_range.start_line, block.output2_range.end_line)
    combined = dumb_combine_inputs(incoming_lines, current_lines, first_input)
  end

  apply_to_result(result_bufnr, block, combined, base_lines)
  gutter.refresh(session)
  auto_refresh.refresh_result_now(result_bufnr)
  return true
end

--- Discard both sides (reset to base) for the conflict under cursor
--- @param tabpage number
--- @return boolean success
function M.discard(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[codediff] No active session", vim.log.levels.WARN)
    return false
  end

  if not session.conflict_blocks or #session.conflict_blocks == 0 then
    vim.notify("[codediff] No conflicts in this session", vim.log.levels.WARN)
    return false
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local side = nil

  if current_buf == session.original_bufnr then
    side = "left"
  elseif current_buf == session.modified_bufnr then
    side = "right"
  else
    vim.notify("[codediff] Cursor not in diff buffer", vim.log.levels.WARN)
    return false
  end

  local block = tracking.find_conflict_at_cursor(session, cursor_line, side, true) -- Allow resolved
  if not block then
    vim.notify("[codediff] No conflict at cursor position", vim.log.levels.INFO)
    return false
  end

  -- Get base content for this range. session.merge_base_lines holds the true
  -- merge base (stage :1) so we can index it by base_range coordinates
  -- regardless of what's been auto-merged into the Result seed.
  local base_lines = session.merge_base_lines or session.result_base_lines
  if not base_lines then
    vim.notify("[codediff] No base lines available", vim.log.levels.ERROR)
    return false
  end

  local base_content = {}
  for i = block.base_range.start_line, block.base_range.end_line - 1 do
    table.insert(base_content, base_lines[i] or "")
  end

  local result_bufnr = session.result_bufnr
  if not result_bufnr then
    vim.notify("[codediff] No result buffer", vim.log.levels.ERROR)
    return false
  end

  -- apply_to_result indexes its base_lines parameter by result_range for the
  -- content-search fallback, so pass the Result seed (auto-merged content).
  apply_to_result(result_bufnr, block, base_content, session.result_base_lines or base_lines)
  gutter.refresh(session)
  auto_refresh.refresh_result_now(result_bufnr)
  return true
end

return M
