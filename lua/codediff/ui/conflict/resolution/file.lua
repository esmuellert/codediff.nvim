-- Resolution commands for every conflict block in the current file.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local auto_refresh = require("codediff.ui.auto_refresh")
local tracking = require("codediff.ui.conflict.tracking")
local gutter = require("codediff.ui.conflict.gutter")
local apply_to_result = require("codediff.ui.conflict.resolution.replace").apply_to_result

--- Accept ALL incoming (left/input1) for all active conflicts
--- @param tabpage number
--- @return boolean success
function M.accept_all_incoming(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[codediff] No active session", vim.log.levels.WARN)
    return false
  end

  if not session.conflict_blocks or #session.conflict_blocks == 0 then
    vim.notify("[codediff] No conflicts in this session", vim.log.levels.WARN)
    return false
  end

  local result_bufnr = session.result_bufnr
  local base_lines = session.result_base_lines
  if not result_bufnr or not base_lines then
    vim.notify("[codediff] No result buffer or base lines", vim.log.levels.ERROR)
    return false
  end

  local count = 0

  -- Process blocks in REVERSE order (bottom-to-top) to avoid line offset issues
  -- Wrap in undojoin for atomic undo
  vim.api.nvim_buf_call(result_bufnr, function()
    for i = #session.conflict_blocks, 1, -1 do
      local block = session.conflict_blocks[i]
      if tracking.is_block_active(session, block) then
        if count > 0 then
          pcall(vim.cmd, "undojoin")
        end
        local incoming_lines = tracking.get_lines_for_range(session.original_bufnr, block.output1_range.start_line, block.output1_range.end_line)
        apply_to_result(result_bufnr, block, incoming_lines, base_lines)
        count = count + 1
      end
    end
  end)

  gutter.refresh(session)
  auto_refresh.refresh_result_now(result_bufnr)
  vim.notify(string.format("[codediff] Accepted %d incoming change(s)", count), vim.log.levels.INFO)
  return count > 0
end

--- Accept ALL current (right/input2) for all active conflicts
--- @param tabpage number
--- @return boolean success
function M.accept_all_current(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[codediff] No active session", vim.log.levels.WARN)
    return false
  end

  if not session.conflict_blocks or #session.conflict_blocks == 0 then
    vim.notify("[codediff] No conflicts in this session", vim.log.levels.WARN)
    return false
  end

  local result_bufnr = session.result_bufnr
  local base_lines = session.result_base_lines
  if not result_bufnr or not base_lines then
    vim.notify("[codediff] No result buffer or base lines", vim.log.levels.ERROR)
    return false
  end

  local count = 0

  vim.api.nvim_buf_call(result_bufnr, function()
    for i = #session.conflict_blocks, 1, -1 do
      local block = session.conflict_blocks[i]
      if tracking.is_block_active(session, block) then
        if count > 0 then
          pcall(vim.cmd, "undojoin")
        end
        local current_lines = tracking.get_lines_for_range(session.modified_bufnr, block.output2_range.start_line, block.output2_range.end_line)
        apply_to_result(result_bufnr, block, current_lines, base_lines)
        count = count + 1
      end
    end
  end)

  gutter.refresh(session)
  auto_refresh.refresh_result_now(result_bufnr)
  vim.notify(string.format("[codediff] Accepted %d current change(s)", count), vim.log.levels.INFO)
  return count > 0
end

--- Accept ALL both sides for all active conflicts
--- @param tabpage number
--- @param first_input number|nil Which input comes first (1=incoming, 2=current). Default: 1
--- @return boolean success
function M.accept_all_both(tabpage, first_input)
  first_input = first_input or 1

  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[codediff] No active session", vim.log.levels.WARN)
    return false
  end

  if not session.conflict_blocks or #session.conflict_blocks == 0 then
    vim.notify("[codediff] No conflicts in this session", vim.log.levels.WARN)
    return false
  end

  local result_bufnr = session.result_bufnr
  local base_lines = session.result_base_lines
  if not result_bufnr or not base_lines then
    vim.notify("[codediff] No result buffer or base lines", vim.log.levels.ERROR)
    return false
  end

  local count = 0

  vim.api.nvim_buf_call(result_bufnr, function()
    for i = #session.conflict_blocks, 1, -1 do
      local block = session.conflict_blocks[i]
      if tracking.is_block_active(session, block) then
        if count > 0 then
          pcall(vim.cmd, "undojoin")
        end

        local incoming_lines = tracking.get_lines_for_range(session.original_bufnr, block.output1_range.start_line, block.output1_range.end_line)
        local current_lines = tracking.get_lines_for_range(session.modified_bufnr, block.output2_range.start_line, block.output2_range.end_line)

        -- Combine both sides
        local combined
        if first_input == 1 then
          combined = vim.list_extend(vim.list_extend({}, incoming_lines), current_lines)
        else
          combined = vim.list_extend(vim.list_extend({}, current_lines), incoming_lines)
        end

        apply_to_result(result_bufnr, block, combined, base_lines)
        count = count + 1
      end
    end
  end)

  gutter.refresh(session)
  auto_refresh.refresh_result_now(result_bufnr)
  vim.notify(string.format("[codediff] Accepted %d combined change(s)", count), vim.log.levels.INFO)
  return count > 0
end

--- Discard ALL changes (reset all conflicts to base)
--- @param tabpage number
--- @return boolean success
function M.discard_all(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[codediff] No active session", vim.log.levels.WARN)
    return false
  end

  if not session.conflict_blocks or #session.conflict_blocks == 0 then
    vim.notify("[codediff] No conflicts in this session", vim.log.levels.WARN)
    return false
  end

  local result_bufnr = session.result_bufnr
  local seed_lines = session.result_base_lines
  -- Use the true merge base for the slice we write back; the seed only feeds
  -- the content-search fallback in apply_to_result.
  local base_lines = session.merge_base_lines or seed_lines
  if not result_bufnr or not seed_lines or not base_lines then
    vim.notify("[codediff] No result buffer or base lines", vim.log.levels.ERROR)
    return false
  end

  local count = 0

  vim.api.nvim_buf_call(result_bufnr, function()
    for i = #session.conflict_blocks, 1, -1 do
      local block = session.conflict_blocks[i]
      -- For discard, we reset even resolved conflicts back to base
      if count > 0 then
        pcall(vim.cmd, "undojoin")
      end

      local base_content = {}
      for j = block.base_range.start_line, block.base_range.end_line - 1 do
        table.insert(base_content, base_lines[j] or "")
      end

      apply_to_result(result_bufnr, block, base_content, seed_lines)
      count = count + 1
    end
  end)

  gutter.refresh(session)
  auto_refresh.refresh_result_now(result_bufnr)
  vim.notify(string.format("[codediff] Reset %d conflict(s) to base", count), vim.log.levels.INFO)
  return count > 0
end

return M
