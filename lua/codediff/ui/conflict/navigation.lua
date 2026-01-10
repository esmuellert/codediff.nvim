-- Conflict navigation for merge tool
local M = {}

local lifecycle = require("codediff.ui.lifecycle")

-- Will be injected by init.lua
local tracking = nil
M._set_tracking_module = function(t)
  tracking = t
end

--- Navigate to next conflict
--- @param tabpage number
function M.navigate_next_conflict(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.conflict_blocks then
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  local target_block = nil
  local target_line = nil
  local target_index = 0
  local total_active = 0
  local active_indices = {}

  -- Pre-calculate active conflicts
  for i, block in ipairs(session.conflict_blocks) do
    if tracking.is_block_active(session, block) then
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
    local start = tracking.get_block_start_line(session, item.block, current_buf)
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
    local start = tracking.get_block_start_line(session, item.block, current_buf)
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
    vim.api.nvim_win_set_cursor(0, { target_line, 0 })
    vim.cmd("normal! zz")
    vim.api.nvim_echo({ { string.format("Conflict %d of %d", target_index, total_active), "None" } }, false, {})
  end
end

--- Navigate to previous conflict
--- @param tabpage number
function M.navigate_prev_conflict(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.conflict_blocks then
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  local target_block = nil
  local target_line = nil
  local target_index = 0
  local total_active = 0
  local active_indices = {}

  -- Pre-calculate active conflicts
  for i, block in ipairs(session.conflict_blocks) do
    if tracking.is_block_active(session, block) then
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
    local start = tracking.get_block_start_line(session, item.block, current_buf)
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
    local start = tracking.get_block_start_line(session, item.block, current_buf)
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
    vim.api.nvim_win_set_cursor(0, { target_line, 0 })
    vim.cmd("normal! zz")
    vim.api.nvim_echo({ { string.format("Conflict %d of %d", target_index, total_active), "None" } }, false, {})
  end
end

return M
