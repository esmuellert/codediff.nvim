-- Conflict resolution actions for merge tool
-- Handles accept current/incoming/both/none actions
local M = {}

local lifecycle = require('vscode-diff.render.lifecycle')
local config = require('vscode-diff.config')
local auto_refresh = require('vscode-diff.auto_refresh')

--- Find which conflict block the cursor is in
--- @param cursor_line number 1-based line number
--- @param blocks table List of conflict blocks with output1_range/output2_range
--- @param side string "left" or "right"
--- @return table|nil The conflict block containing the cursor
local function find_conflict_at_cursor(cursor_line, blocks, side)
  local range_key = side == "left" and "output1_range" or "output2_range"
  for _, block in ipairs(blocks) do
    local range = block[range_key]
    if range and cursor_line >= range.start_line and cursor_line < range.end_line then
      return block
    end
  end
  return nil
end

--- Get lines from a buffer for a given range
--- @param bufnr number Buffer number
--- @param start_line number 1-based start line (inclusive)
--- @param end_line number 1-based end line (exclusive)
--- @return table Lines
local function get_lines_for_range(bufnr, start_line, end_line)
  if start_line >= end_line then
    return {}
  end
  return vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line - 1, false)
end

--- Apply text to result buffer at the conflict's base range
--- @param result_bufnr number Result buffer
--- @param base_range table { start_line, end_line }
--- @param lines table Lines to insert
--- @param base_lines table Original BASE content
local function apply_to_result(result_bufnr, base_range, lines, base_lines)
  -- We need to find where this base_range maps to in the current result buffer
  -- The result buffer starts as BASE, so initially base_range maps 1:1
  -- After edits, we need to track the offset

  -- For simplicity, we'll re-apply based on content matching
  -- Find the base content in the result buffer
  local base_content = {}
  for i = base_range.start_line, base_range.end_line - 1 do
    table.insert(base_content, base_lines[i] or "")
  end

  local result_lines = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)

  -- Search for the base content in result buffer
  -- This is a simple approach; VSCode uses more sophisticated tracking
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
    -- Replace the base content with new lines
    vim.api.nvim_buf_set_lines(result_bufnr, found_start - 1, found_start - 1 + #base_content, false, lines)
  else
    -- Fallback: try to find by approximate position
    -- Use base_range directly (works if no prior edits)
    local start_idx = math.min(base_range.start_line - 1, #result_lines)
    local end_idx = math.min(base_range.end_line - 1, #result_lines)
    vim.api.nvim_buf_set_lines(result_bufnr, start_idx, end_idx, false, lines)
  end
end

--- Accept incoming (left/input1) side for the conflict under cursor
--- @param tabpage number
--- @return boolean success
function M.accept_incoming(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[vscode-diff] No active session", vim.log.levels.WARN)
    return false
  end

  if not session.conflict_blocks or #session.conflict_blocks == 0 then
    vim.notify("[vscode-diff] No conflicts in this session", vim.log.levels.WARN)
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
    vim.notify("[vscode-diff] Cursor not in diff buffer", vim.log.levels.WARN)
    return false
  end

  local block = find_conflict_at_cursor(cursor_line, session.conflict_blocks, side)
  if not block then
    vim.notify("[vscode-diff] No conflict at cursor position", vim.log.levels.INFO)
    return false
  end

  -- Get incoming (left) content
  local incoming_lines = get_lines_for_range(session.original_bufnr, block.output1_range.start_line, block.output1_range.end_line)

  -- Apply to result
  local result_bufnr = session.result_bufnr
  local base_lines = session.result_base_lines
  if not result_bufnr or not base_lines then
    vim.notify("[vscode-diff] No result buffer or base lines", vim.log.levels.ERROR)
    return false
  end

  apply_to_result(result_bufnr, block.base_range, incoming_lines, base_lines)
  auto_refresh.refresh_result_now(result_bufnr)
  return true
end

--- Accept current (right/input2) side for the conflict under cursor
--- @param tabpage number
--- @return boolean success
function M.accept_current(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[vscode-diff] No active session", vim.log.levels.WARN)
    return false
  end

  if not session.conflict_blocks or #session.conflict_blocks == 0 then
    vim.notify("[vscode-diff] No conflicts in this session", vim.log.levels.WARN)
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
    vim.notify("[vscode-diff] Cursor not in diff buffer", vim.log.levels.WARN)
    return false
  end

  local block = find_conflict_at_cursor(cursor_line, session.conflict_blocks, side)
  if not block then
    vim.notify("[vscode-diff] No conflict at cursor position", vim.log.levels.INFO)
    return false
  end

  -- Get current (right) content
  local current_lines = get_lines_for_range(session.modified_bufnr, block.output2_range.start_line, block.output2_range.end_line)

  local result_bufnr = session.result_bufnr
  local base_lines = session.result_base_lines
  if not result_bufnr or not base_lines then
    vim.notify("[vscode-diff] No result buffer or base lines", vim.log.levels.ERROR)
    return false
  end

  apply_to_result(result_bufnr, block.base_range, current_lines, base_lines)
  auto_refresh.refresh_result_now(result_bufnr)
  return true
end

--- Accept both sides (incoming first, then current) for the conflict under cursor
--- @param tabpage number
--- @return boolean success
function M.accept_both(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[vscode-diff] No active session", vim.log.levels.WARN)
    return false
  end

  if not session.conflict_blocks or #session.conflict_blocks == 0 then
    vim.notify("[vscode-diff] No conflicts in this session", vim.log.levels.WARN)
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
    vim.notify("[vscode-diff] Cursor not in diff buffer", vim.log.levels.WARN)
    return false
  end

  local block = find_conflict_at_cursor(cursor_line, session.conflict_blocks, side)
  if not block then
    vim.notify("[vscode-diff] No conflict at cursor position", vim.log.levels.INFO)
    return false
  end

  -- Get both contents
  local incoming_lines = get_lines_for_range(session.original_bufnr, block.output1_range.start_line, block.output1_range.end_line)
  local current_lines = get_lines_for_range(session.modified_bufnr, block.output2_range.start_line, block.output2_range.end_line)

  -- Combine: incoming first, then current
  local combined = {}
  for _, line in ipairs(incoming_lines) do
    table.insert(combined, line)
  end
  for _, line in ipairs(current_lines) do
    table.insert(combined, line)
  end

  local result_bufnr = session.result_bufnr
  local base_lines = session.result_base_lines
  if not result_bufnr or not base_lines then
    vim.notify("[vscode-diff] No result buffer or base lines", vim.log.levels.ERROR)
    return false
  end

  apply_to_result(result_bufnr, block.base_range, combined, base_lines)
  auto_refresh.refresh_result_now(result_bufnr)
  return true
end

--- Discard both sides (reset to base) for the conflict under cursor
--- @param tabpage number
--- @return boolean success
function M.discard(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[vscode-diff] No active session", vim.log.levels.WARN)
    return false
  end

  if not session.conflict_blocks or #session.conflict_blocks == 0 then
    vim.notify("[vscode-diff] No conflicts in this session", vim.log.levels.WARN)
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
    vim.notify("[vscode-diff] Cursor not in diff buffer", vim.log.levels.WARN)
    return false
  end

  local block = find_conflict_at_cursor(cursor_line, session.conflict_blocks, side)
  if not block then
    vim.notify("[vscode-diff] No conflict at cursor position", vim.log.levels.INFO)
    return false
  end

  -- Get base content for this range
  local base_lines = session.result_base_lines
  if not base_lines then
    vim.notify("[vscode-diff] No base lines available", vim.log.levels.ERROR)
    return false
  end

  local base_content = {}
  for i = block.base_range.start_line, block.base_range.end_line - 1 do
    table.insert(base_content, base_lines[i] or "")
  end

  local result_bufnr = session.result_bufnr
  if not result_bufnr then
    vim.notify("[vscode-diff] No result buffer", vim.log.levels.ERROR)
    return false
  end

  apply_to_result(result_bufnr, block.base_range, base_content, base_lines)
  auto_refresh.refresh_result_now(result_bufnr)
  return true
end

--- Setup conflict keymaps for a session
--- @param tabpage number
function M.setup_keymaps(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then return end

  local keymaps = config.options.keymaps.conflict or {}

  -- Only bind to incoming (left) and current (right) buffers
  local buffers = { session.original_bufnr, session.modified_bufnr }

  local base_opts = { noremap = true, silent = true, nowait = true }

  for _, bufnr in ipairs(buffers) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      -- Accept incoming
      if keymaps.accept_incoming then
        vim.keymap.set("n", keymaps.accept_incoming, function()
          M.accept_incoming(tabpage)
        end, vim.tbl_extend('force', base_opts, { buffer = bufnr, desc = "Accept incoming change" }))
      end

      -- Accept current
      if keymaps.accept_current then
        vim.keymap.set("n", keymaps.accept_current, function()
          M.accept_current(tabpage)
        end, vim.tbl_extend('force', base_opts, { buffer = bufnr, desc = "Accept current change" }))
      end

      -- Accept both
      if keymaps.accept_both then
        vim.keymap.set("n", keymaps.accept_both, function()
          M.accept_both(tabpage)
        end, vim.tbl_extend('force', base_opts, { buffer = bufnr, desc = "Accept both changes" }))
      end

      -- Discard
      if keymaps.discard then
        vim.keymap.set("n", keymaps.discard, function()
          M.discard(tabpage)
        end, vim.tbl_extend('force', base_opts, { buffer = bufnr, desc = "Discard changes (keep base)" }))
      end
    end
  end
end

return M
