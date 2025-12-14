-- Conflict resolution actions for merge tool
-- Handles accept current/incoming/both/none actions
local M = {}

local lifecycle = require('vscode-diff.render.lifecycle')
local config = require('vscode-diff.config')
local auto_refresh = require('vscode-diff.auto_refresh')

local tracking_ns = vim.api.nvim_create_namespace("vscode-diff-conflict-tracking")

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
local function make_repeatable(fn)
  return function()
    _pending_action = fn
    vim.go.operatorfunc = "v:lua.require'vscode-diff.render.conflict_actions'.run_repeatable_action"
    return "g@l"
  end
end

--- Check if a conflict block is currently active (content matches base)
--- @param session table The diff session
--- @param block table The conflict block
--- @return boolean is_active
local function is_block_active(session, block)
  if not block.extmark_id then return false end
  
  -- 1. Get current content from buffer via Extmark
  local mark = vim.api.nvim_buf_get_extmark_by_id(session.result_bufnr, tracking_ns, block.extmark_id, { details = true })
  if not mark or #mark == 0 then return false end
  
  local start_row = mark[1]
  local end_row = mark[3].end_row
  
  local current_lines = vim.api.nvim_buf_get_lines(session.result_bufnr, start_row, end_row, false)
  
  -- 2. Get expected base content from session
  local base_lines = session.result_base_lines
  if not base_lines then return false end
  
  local expected_lines = {}
  -- base_range is 1-based, inclusive-exclusive logic?
  -- In `apply_to_result`, we used: for i = base_range.start_line, base_range.end_line - 1
  -- Let's match that.
  for i = block.base_range.start_line, block.base_range.end_line - 1 do
    table.insert(expected_lines, base_lines[i] or "")
  end
  
  -- 3. Compare
  if #current_lines ~= #expected_lines then return false end
  
  for i = 1, #current_lines do
    if current_lines[i] ~= expected_lines[i] then
      return false
    end
  end
  
  return true
end

--- Find which conflict block the cursor is in
--- @param session table The diff session
--- @param cursor_line number 1-based line number
--- @param side string "left" or "right"
--- @param allow_resolved boolean? If true, return block even if resolved (for discard/reset)
--- @return table|nil The conflict block containing the cursor
local function find_conflict_at_cursor(session, cursor_line, side, allow_resolved)
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
      if is_block_active(session, block) then
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

--- Initialize extmark tracking for conflict blocks in the result buffer
--- @param result_bufnr number Result buffer handle
--- @param conflict_blocks table List of conflict blocks
function M.initialize_tracking(result_bufnr, conflict_blocks)
  if not result_bufnr or not vim.api.nvim_buf_is_valid(result_bufnr) then return end
  
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
      end_right_gravity = true
    })
    
    block.extmark_id = id
  end
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
    local mark = vim.api.nvim_buf_get_extmark_by_id(result_bufnr, tracking_ns, block.extmark_id, { details = true })
    if mark and #mark >= 3 then
      start_row = mark[1]
      end_row = mark[3].end_row
    end
  end
  
  -- Method 2: Fallback to content search or original range
  if not start_row then
    local base_range = block.base_range
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
      start_row = found_start - 1
      end_row = found_start - 1 + #base_content
    else
      -- Fallback: try to find by approximate position
      -- Use base_range directly (works if no prior edits)
      start_row = math.min(base_range.start_line - 1, #result_lines)
      end_row = math.min(base_range.end_line - 1, #result_lines)
    end
  end
  
  if start_row and end_row then
    vim.api.nvim_buf_set_lines(result_bufnr, start_row, end_row, false, lines)
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

  local block = find_conflict_at_cursor(session, cursor_line, side, false)
  if not block then
    vim.notify("[vscode-diff] No active conflict at cursor position", vim.log.levels.INFO)
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

  apply_to_result(result_bufnr, block, incoming_lines, base_lines)
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

  local block = find_conflict_at_cursor(session, cursor_line, side, false)
  if not block then
    vim.notify("[vscode-diff] No active conflict at cursor position", vim.log.levels.INFO)
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

  apply_to_result(result_bufnr, block, current_lines, base_lines)
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

  local block = find_conflict_at_cursor(session, cursor_line, side, false)
  if not block then
    vim.notify("[vscode-diff] No active conflict at cursor position", vim.log.levels.INFO)
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

  apply_to_result(result_bufnr, block, combined, base_lines)
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

  local block = find_conflict_at_cursor(session, cursor_line, side, true) -- Allow resolved
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

  apply_to_result(result_bufnr, block, base_content, base_lines)
  auto_refresh.refresh_result_now(result_bufnr)
  return true
end

--- Get the start line of a block in the current buffer
--- @param session table Session object
--- @param block table Conflict block
--- @param bufnr number Current buffer number
--- @return number|nil start_line 1-based
local function get_block_start_line(session, block, bufnr)
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

--- Navigate to next conflict
--- @param tabpage number
function M.navigate_next_conflict(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.conflict_blocks then return end

  local current_buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  
  local target_block = nil
  local target_line = nil
  local target_index = 0
  local total_active = 0
  local active_indices = {}

  -- Pre-calculate active conflicts
  for i, block in ipairs(session.conflict_blocks) do
    if is_block_active(session, block) then
      total_active = total_active + 1
      table.insert(active_indices, { block = block, index = i })
    end
  end

  if total_active == 0 then
    vim.notify("No active conflicts", vim.log.levels.INFO)
    return
  end

  -- Find next
  for i, item in ipairs(active_indices) do
    local start = get_block_start_line(session, item.block, current_buf)
    if start and start > cursor_line then
      target_block = item.block
      target_line = start
      target_index = i
      break
    end
  end

  -- Wrap around
  if not target_line then
    local item = active_indices[1]
    local start = get_block_start_line(session, item.block, current_buf)
    if start then
      target_block = item.block
      target_line = start
      target_index = 1
    end
    
    if target_line and target_line < cursor_line then
       -- Wrapped
    else
       -- Should not happen if total_active > 0
       return
    end
  end

  if target_line then
    vim.api.nvim_win_set_cursor(0, {target_line, 0})
    vim.cmd("normal! zz")
    vim.api.nvim_echo({{string.format('Conflict %d of %d', target_index, total_active), 'None'}}, false, {})
  end
end

--- Navigate to previous conflict
--- @param tabpage number
function M.navigate_prev_conflict(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.conflict_blocks then return end

  local current_buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  
  local target_block = nil
  local target_line = nil
  local target_index = 0
  local total_active = 0
  local active_indices = {}

  -- Pre-calculate active conflicts
  for i, block in ipairs(session.conflict_blocks) do
    if is_block_active(session, block) then
      total_active = total_active + 1
      table.insert(active_indices, { block = block, index = i })
    end
  end

  if total_active == 0 then
    vim.notify("No active conflicts", vim.log.levels.INFO)
    return
  end

  -- Find previous (iterate backwards through active list)
  for i = #active_indices, 1, -1 do
    local item = active_indices[i]
    local start = get_block_start_line(session, item.block, current_buf)
    if start and start < cursor_line then
      target_block = item.block
      target_line = start
      target_index = i
      break
    end
  end

  -- Wrap around
  if not target_line then
    local item = active_indices[#active_indices]
    local start = get_block_start_line(session, item.block, current_buf)
    if start then
      target_block = item.block
      target_line = start
      target_index = #active_indices
    end
    
    if target_line and target_line > cursor_line then
       -- Wrapped
    else
       return
    end
  end

  if target_line then
    vim.api.nvim_win_set_cursor(0, {target_line, 0})
    vim.cmd("normal! zz")
    vim.api.nvim_echo({{string.format('Conflict %d of %d', target_index, total_active), 'None'}}, false, {})
  end
end

--- Setup conflict keymaps for a session
--- @param tabpage number
function M.setup_keymaps(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then return end

  local keymaps = config.options.keymaps.conflict or {}

  -- Bind to incoming (left), current (right), AND result buffers
  local buffers = { session.original_bufnr, session.modified_bufnr, session.result_bufnr }

  local base_opts = { noremap = true, silent = true, nowait = true }

  for _, bufnr in ipairs(buffers) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      -- Accept incoming
      if keymaps.accept_incoming then
        vim.keymap.set("n", keymaps.accept_incoming, make_repeatable(function()
          M.accept_incoming(tabpage)
        end), vim.tbl_extend('force', base_opts, { buffer = bufnr, desc = "Accept incoming change", expr = true }))
      end

      -- Accept current
      if keymaps.accept_current then
        vim.keymap.set("n", keymaps.accept_current, make_repeatable(function()
          M.accept_current(tabpage)
        end), vim.tbl_extend('force', base_opts, { buffer = bufnr, desc = "Accept current change", expr = true }))
      end

      -- Accept both
      if keymaps.accept_both then
        vim.keymap.set("n", keymaps.accept_both, make_repeatable(function()
          M.accept_both(tabpage)
        end), vim.tbl_extend('force', base_opts, { buffer = bufnr, desc = "Accept both changes", expr = true }))
      end

      -- Discard
      if keymaps.discard then
        vim.keymap.set("n", keymaps.discard, make_repeatable(function()
          M.discard(tabpage)
        end), vim.tbl_extend('force', base_opts, { buffer = bufnr, desc = "Discard changes (keep base)", expr = true }))
      end
      
      -- Navigation
      if keymaps.next_conflict then
        vim.keymap.set("n", keymaps.next_conflict, function()
          M.navigate_next_conflict(tabpage)
        end, vim.tbl_extend('force', base_opts, { buffer = bufnr, desc = "Next conflict" }))
      end
      
      if keymaps.prev_conflict then
        vim.keymap.set("n", keymaps.prev_conflict, function()
          M.navigate_prev_conflict(tabpage)
        end, vim.tbl_extend('force', base_opts, { buffer = bufnr, desc = "Previous conflict" }))
      end
    end
  end
end

return M