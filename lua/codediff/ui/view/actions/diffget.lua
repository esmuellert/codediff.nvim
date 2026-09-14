-- Vimdiff-style do/dp: move a hunk between the two panes.
--
-- In inline layout there is only one pane, so `do` reverts the hunk to the
-- original and `dp` has nothing to do.

local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local refresh = require("codediff.ui.refresh")
local hunk_actions = require("codediff.ui.view.actions.hunk")

function M.diff_get(ctx)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session then
    return
  end

  if ctx.is_inline then
    -- Inline mode: revert modified lines to original
    if not vim.bo[ctx.modified_bufnr].modifiable then
      vim.notify("Buffer is not modifiable", vim.log.levels.WARN)
      return
    end

    local hunk, hunk_idx = hunk_actions.find_hunk_at_cursor(ctx)
    if not hunk then
      vim.notify("No hunk at cursor position", vim.log.levels.WARN)
      return
    end

    local orig_lines = vim.api.nvim_buf_get_lines(ctx.original_bufnr, hunk.original.start_line - 1, hunk.original.end_line - 1, false)
    vim.api.nvim_buf_set_lines(ctx.modified_bufnr, hunk.modified.start_line - 1, hunk.modified.end_line - 1, false, orig_lines)
    refresh.buffer_changed(ctx.modified_bufnr)
    vim.api.nvim_echo({ { string.format("Reverted hunk %d", hunk_idx), "None" } }, false, {})
    return
  end

  -- Side-by-side mode: copy from other buffer to current
  local current_buf = vim.api.nvim_get_current_buf()
  local is_original = current_buf == ctx.original_bufnr
  local target_buf = current_buf
  local source_buf = is_original and ctx.modified_bufnr or ctx.original_bufnr

  -- Check if target buffer is modifiable
  if not vim.bo[target_buf].modifiable then
    vim.notify("Buffer is not modifiable", vim.log.levels.WARN)
    return
  end

  local hunk, hunk_idx = hunk_actions.find_hunk_at_cursor(ctx)
  if not hunk then
    vim.notify("No hunk at cursor position", vim.log.levels.WARN)
    return
  end

  -- Get source and target ranges
  local source_range = is_original and hunk.modified or hunk.original
  local target_range = is_original and hunk.original or hunk.modified

  -- Get lines from source buffer
  local source_lines = vim.api.nvim_buf_get_lines(source_buf, source_range.start_line - 1, source_range.end_line - 1, false)

  -- Replace lines in target buffer
  vim.api.nvim_buf_set_lines(target_buf, target_range.start_line - 1, target_range.end_line - 1, false, source_lines)

  -- Trigger diff refresh to update highlights
  refresh.buffer_changed(target_buf)

  vim.api.nvim_echo({ { string.format("Obtained hunk %d", hunk_idx), "None" } }, false, {})
end

function M.diff_put(ctx)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session then
    return
  end

  if ctx.is_inline then
    -- Inline mode: buffer already has modified content, dp is a no-op
    vim.notify("Buffer already contains the modified version. Use 'do' to revert to original.", vim.log.levels.INFO)
    return
  end

  -- Side-by-side mode: copy from current buffer to other
  local current_buf = vim.api.nvim_get_current_buf()
  local is_original = current_buf == ctx.original_bufnr
  local source_buf = current_buf
  local target_buf = is_original and ctx.modified_bufnr or ctx.original_bufnr

  -- Check if target buffer is modifiable
  if not vim.bo[target_buf].modifiable then
    vim.notify("Target buffer is not modifiable", vim.log.levels.WARN)
    return
  end

  local hunk, hunk_idx = hunk_actions.find_hunk_at_cursor(ctx)
  if not hunk then
    vim.notify("No hunk at cursor position", vim.log.levels.WARN)
    return
  end

  -- Get source and target ranges
  local source_range = is_original and hunk.original or hunk.modified
  local target_range = is_original and hunk.modified or hunk.original

  -- Get lines from source buffer
  local source_lines = vim.api.nvim_buf_get_lines(source_buf, source_range.start_line - 1, source_range.end_line - 1, false)

  -- Replace lines in target buffer
  vim.api.nvim_buf_set_lines(target_buf, target_range.start_line - 1, target_range.end_line - 1, false, source_lines)

  -- Trigger diff refresh to update highlights
  refresh.buffer_changed(target_buf)

  vim.api.nvim_echo({ { string.format("Put hunk %d", hunk_idx), "None" } }, false, {})
end

return M
