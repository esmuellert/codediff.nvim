-- Conflict block tracking via extmarks
-- Handles tracking state, checking if blocks are active/resolved
local M = {}

local lifecycle = require("codediff.ui.lifecycle")

local tracking_ns = vim.api.nvim_create_namespace("codediff-conflict-tracking")
local result_signs_ns = vim.api.nvim_create_namespace("codediff-result-signs")

-- Expose namespaces for other modules
M.tracking_ns = tracking_ns
M.result_signs_ns = result_signs_ns

-- State for dot-repeat
local _pending_action = nil

--- Operatorfunc callback for dot-repeat
--- @param type string Motion type (ignored)
function M.run_repeatable_action(type)
  if _pending_action then
    _pending_action()
  end
end

--- Wrap a function to be dot-repeatable via operatorfunc
--- @param fn function The action to perform
--- @return function The wrapper that sets operatorfunc and returns 'g@l'
function M.make_repeatable(fn)
  return function()
    _pending_action = fn
    vim.go.operatorfunc = "v:lua.require'codediff.ui.conflict'.run_repeatable_action"
    return "g@l"
  end
end

--- Check if a conflict block is currently active (content matches base)
--- @param session table The diff session
--- @param block table The conflict block
--- @return boolean is_active
function M.is_block_active(session, block)
  if not block.extmark_id then
    return true
  end -- Default to active if no tracking

  -- 1. Get current content from buffer via Extmark
  local mark = vim.api.nvim_buf_get_extmark_by_id(session.result_bufnr, tracking_ns, block.extmark_id, { details = true })
  if not mark or #mark == 0 then
    return true
  end -- Default to active if extmark invalid
  if not mark[3] or mark[3].end_row == nil then
    return true
  end -- Default to active if details missing

  local start_row = mark[1]
  local end_row = mark[3].end_row

  local current_lines = vim.api.nvim_buf_get_lines(session.result_bufnr, start_row, end_row, false)

  -- 2. Get expected base content from session
  local base_lines = session.result_base_lines
  if not base_lines then
    return true
  end -- Default to active if no base lines

  local expected_lines = {}
  -- base_range is 1-based, inclusive-exclusive logic?
  -- In `apply_to_result`, we used: for i = base_range.start_line, base_range.end_line - 1
  -- Let's match that.
  for i = block.base_range.start_line, block.base_range.end_line - 1 do
    table.insert(expected_lines, base_lines[i] or "")
  end

  -- 3. Compare
  if #current_lines ~= #expected_lines then
    return false
  end

  for i = 1, #current_lines do
    if current_lines[i] ~= expected_lines[i] then
      return false
    end
  end

  return true
end

--- Determine which side was accepted for a resolved conflict block
--- @param session table The diff session
--- @param block table The conflict block
--- @return string|nil "incoming", "current", "both", or nil if unresolved/unknown
function M.get_accepted_side(session, block)
  if not block.extmark_id then
    return nil
  end
  if M.is_block_active(session, block) then
    return nil
  end -- Still unresolved

  -- Get current content from result buffer
  local mark = vim.api.nvim_buf_get_extmark_by_id(session.result_bufnr, tracking_ns, block.extmark_id, { details = true })
  if not mark or #mark < 3 then
    return nil
  end

  local start_row = mark[1]
  local end_row = mark[3].end_row
  local current_lines = vim.api.nvim_buf_get_lines(session.result_bufnr, start_row, end_row, false)

  -- Get incoming (left) content
  local incoming_lines = {}
  if session.original_bufnr and vim.api.nvim_buf_is_valid(session.original_bufnr) then
    local left_start = block.output1_range.start_line
    local left_end = block.output1_range.end_line
    incoming_lines = vim.api.nvim_buf_get_lines(session.original_bufnr, left_start - 1, left_end - 1, false)
  end

  -- Get current (right) content
  local current_side_lines = {}
  if session.modified_bufnr and vim.api.nvim_buf_is_valid(session.modified_bufnr) then
    local right_start = block.output2_range.start_line
    local right_end = block.output2_range.end_line
    current_side_lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, right_start - 1, right_end - 1, false)
  end

  -- Helper to compare line arrays
  local function lines_equal(a, b)
    if #a ~= #b then
      return false
    end
    for i = 1, #a do
      if a[i] ~= b[i] then
        return false
      end
    end
    return true
  end

  -- Check which side matches
  local matches_incoming = lines_equal(current_lines, incoming_lines)
  local matches_current = lines_equal(current_lines, current_side_lines)

  if matches_incoming and matches_current then
    return "both" -- Both sides are the same (shouldn't happen in conflict, but handle it)
  elseif matches_incoming then
    return "incoming"
  elseif matches_current then
    return "current"
  else
    -- Content doesn't match either side exactly (could be "both" concatenated or manual edit)
    -- Check if it's both sides concatenated
    local both_lines = {}
    for _, line in ipairs(incoming_lines) do
      table.insert(both_lines, line)
    end
    for _, line in ipairs(current_side_lines) do
      table.insert(both_lines, line)
    end
    if lines_equal(current_lines, both_lines) then
      return "both"
    end
    return "edited" -- Manual edit or unknown
  end
end

--- Find which conflict block the cursor is in
--- @param session table The diff session
--- @param cursor_line number 1-based line number
--- @param side string "left" or "right"
--- @param allow_resolved boolean? If true, return block even if resolved (for discard/reset)
--- @return table|nil The conflict block containing the cursor
function M.find_conflict_at_cursor(session, cursor_line, side, allow_resolved)
  local blocks = session.conflict_blocks
  local range_key = side == "left" and "output1_range" or "output2_range"

  for _, block in ipairs(blocks) do
    local is_match = false

    if allow_resolved then
      -- Just check if extmark exists (valid block tracking)
      if block.extmark_id then
        local mark = vim.api.nvim_buf_get_extmark_by_id(session.result_bufnr, tracking_ns, block.extmark_id, {})
        if mark and #mark > 0 then
          is_match = true
        end
      end
    else
      -- Check strictly if active (content matches base)
      if M.is_block_active(session, block) then
        is_match = true
      end
    end

    if is_match then
      local range = block[range_key]
      if range and cursor_line >= range.start_line and cursor_line < range.end_line then
        return block
      end
    end
  end
  return nil
end

--- Find conflict block at cursor position in result buffer (using extmarks)
--- @param session table The diff session
--- @param cursor_line number 1-based line number in result buffer
--- @return table|nil The conflict block containing the cursor
function M.find_conflict_at_cursor_in_result(session, cursor_line)
  local blocks = session.conflict_blocks
  if not blocks then
    return nil
  end

  for _, block in ipairs(blocks) do
    if block.extmark_id then
      local mark = vim.api.nvim_buf_get_extmark_by_id(session.result_bufnr, tracking_ns, block.extmark_id, { details = true })
      if mark and #mark > 0 then
        local start_row = mark[1] + 1 -- Convert to 1-based
        local end_row = mark[3] and mark[3].end_row and (mark[3].end_row + 1) or start_row

        -- Check if cursor is within this block's range in result buffer
        if cursor_line >= start_row and cursor_line <= end_row then
          -- Also check if block is still active (not resolved)
          if M.is_block_active(session, block) then
            return block
          end
        end
      end
    end
  end
  return nil
end

--- Get lines from a buffer for a given range
--- @param bufnr number Buffer number
--- @param start_line number 1-based start line (inclusive)
--- @param end_line number 1-based end line (exclusive)
--- @return table Lines
function M.get_lines_for_range(bufnr, start_line, end_line)
  if start_line >= end_line then
    return {}
  end
  return vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line - 1, false)
end

--- Initialize extmark tracking for conflict blocks in the result buffer
--- @param result_bufnr number Result buffer handle
--- @param conflict_blocks table List of conflict blocks
function M.initialize_tracking(result_bufnr, conflict_blocks)
  if not result_bufnr or not vim.api.nvim_buf_is_valid(result_bufnr) then
    return
  end

  -- Clear existing extmarks in our namespace
  vim.api.nvim_buf_clear_namespace(result_bufnr, tracking_ns, 0, -1)

  for _, block in ipairs(conflict_blocks) do
    local start_line = block.base_range.start_line - 1
    local end_line = block.base_range.end_line - 1

    -- Create extmark with gravity: right (adjusts as text is inserted before it)
    -- We want to track the *range* of this block.
    -- Since we replace the whole block content, tracking the start point is most critical.
    -- We use end_right_gravity=false so that if we insert *at* the end, it doesn't expand (though we replace usually).
    local id = vim.api.nvim_buf_set_extmark(result_bufnr, tracking_ns, start_line, 0, {
      end_row = end_line,
      end_col = 0,
      right_gravity = false,
      end_right_gravity = true,
    })

    block.extmark_id = id
  end
end

--- Get the start line of a block in the current buffer
--- @param session table Session object
--- @param block table Conflict block
--- @param bufnr number Current buffer number
--- @return number|nil start_line 1-based
function M.get_block_start_line(session, block, bufnr)
  if bufnr == session.result_bufnr then
    -- Result buffer: use extmark
    if block.extmark_id then
      local mark = vim.api.nvim_buf_get_extmark_by_id(session.result_bufnr, tracking_ns, block.extmark_id, {})
      if mark and #mark > 0 then
        return mark[1] + 1 -- Extmarks are 0-based, return 1-based
      end
    end
  elseif bufnr == session.original_bufnr then
    -- Incoming (left): use output1_range
    if block.output1_range then
      return block.output1_range.start_line
    end
  elseif bufnr == session.modified_bufnr then
    -- Current (right): use output2_range
    if block.output2_range then
      return block.output2_range.start_line
    end
  end
  return nil
end

return M
