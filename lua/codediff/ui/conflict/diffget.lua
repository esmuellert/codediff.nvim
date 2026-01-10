-- Vimdiff-style diffget operations for merge tool
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local auto_refresh = require("codediff.ui.auto_refresh")

-- Will be injected by init.lua
local tracking = nil
local signs = nil
M._set_tracking_module = function(t)
  tracking = t
end
M._set_signs_module = function(s)
  signs = s
end

--- Apply text to result buffer at the conflict's range
--- @param result_bufnr number Result buffer
--- @param block table Conflict block with base_range and optional extmark_id
--- @param lines table Lines to insert
--- @param base_lines table Original BASE content (for fallback)
local function apply_to_result(result_bufnr, block, lines, base_lines)
  local start_row, end_row

  -- Method 1: Try using extmarks (robust against edits)
  if block.extmark_id then
    local mark = vim.api.nvim_buf_get_extmark_by_id(result_bufnr, tracking.tracking_ns, block.extmark_id, { details = true })
    if mark and #mark >= 3 then
      start_row = mark[1]
      end_row = mark[3].end_row
    end
  end

  -- Method 2: Fallback to content search or original range
  if not start_row then
    local base_range = block.base_range
    local base_content = {}
    for i = base_range.start_line, base_range.end_line - 1 do
      table.insert(base_content, base_lines[i] or "")
    end

    local result_lines = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)

    local found_start = nil
    for i = 1, #result_lines - #base_content + 1 do
      local match = true
      for j = 1, #base_content do
        if result_lines[i + j - 1] ~= base_content[j] then
          match = false
          break
        end
      end
      if match then
        found_start = i
        break
      end
    end

    if found_start then
      start_row = found_start - 1
      end_row = found_start - 1 + #base_content
    else
      start_row = math.min(base_range.start_line - 1, #result_lines)
      end_row = math.min(base_range.end_line - 1, #result_lines)
    end
  end

  if start_row and end_row then
    vim.api.nvim_buf_set_lines(result_bufnr, start_row, end_row, false, lines)
  end
end

--- Vimdiff-style diffget from incoming (2do): get hunk from incoming/theirs buffer to result
--- Works from result buffer only (like vimdiff's :diffget 2)
--- @param tabpage number
--- @return boolean success
function M.diffget_incoming(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[codediff] No active session", vim.log.levels.WARN)
    return false
  end

  local current_buf = vim.api.nvim_get_current_buf()

  if current_buf ~= session.result_bufnr then
    vim.notify("[codediff] 2do only works from result buffer", vim.log.levels.INFO)
    return false
  end

  if not session.conflict_blocks or #session.conflict_blocks == 0 then
    vim.notify("[codediff] No conflicts in this session", vim.log.levels.WARN)
    return false
  end

  -- Find conflict at cursor position in result buffer
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local block = tracking.find_conflict_at_cursor_in_result(session, cursor_line)
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
  signs.refresh_all_conflict_signs(session)
  auto_refresh.refresh_result_now(result_bufnr)
  return true
end

--- Vimdiff-style diffget from current (3do): get hunk from current/ours buffer to result
--- Works from result buffer only (like vimdiff's :diffget 3)
--- @param tabpage number
--- @return boolean success
function M.diffget_current(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[codediff] No active session", vim.log.levels.WARN)
    return false
  end

  local current_buf = vim.api.nvim_get_current_buf()

  if current_buf ~= session.result_bufnr then
    vim.notify("[codediff] 3do only works from result buffer", vim.log.levels.INFO)
    return false
  end

  if not session.conflict_blocks or #session.conflict_blocks == 0 then
    vim.notify("[codediff] No conflicts in this session", vim.log.levels.WARN)
    return false
  end

  -- Find conflict at cursor position in result buffer
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local block = tracking.find_conflict_at_cursor_in_result(session, cursor_line)
  if not block then
    vim.notify("[codediff] No active conflict at cursor position", vim.log.levels.INFO)
    return false
  end

  -- Get current (right) content
  local current_lines = tracking.get_lines_for_range(session.modified_bufnr, block.output2_range.start_line, block.output2_range.end_line)

  -- Apply to result
  local result_bufnr = session.result_bufnr
  local base_lines = session.result_base_lines
  if not result_bufnr or not base_lines then
    vim.notify("[codediff] No result buffer or base lines", vim.log.levels.ERROR)
    return false
  end

  apply_to_result(result_bufnr, block, current_lines, base_lines)
  signs.refresh_all_conflict_signs(session)
  auto_refresh.refresh_result_now(result_bufnr)
  return true
end

return M
