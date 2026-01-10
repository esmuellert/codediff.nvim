-- Diff computation and rendering for diff view
local M = {}

local core = require("codediff.ui.core")
local semantic = require("codediff.ui.semantic_tokens")
local config = require("codediff.config")
local diff_module = require("codediff.core.diff")

-- Common logic: Compute diff and render highlights
-- @param auto_scroll_to_first_hunk boolean: Whether to auto-scroll to first change (default true)
function M.compute_and_render(
  original_buf,
  modified_buf,
  original_lines,
  modified_lines,
  original_is_virtual,
  modified_is_virtual,
  original_win,
  modified_win,
  auto_scroll_to_first_hunk
)
  -- Compute diff
  local diff_options = {
    max_computation_time_ms = config.options.diff.max_computation_time_ms,
  }
  local lines_diff = diff_module.compute_diff(original_lines, modified_lines, diff_options)
  if not lines_diff then
    vim.notify("Failed to compute diff", vim.log.levels.ERROR)
    return nil
  end

  -- Render diff highlights
  core.render_diff(original_buf, modified_buf, original_lines, modified_lines, lines_diff)

  -- Apply semantic tokens for virtual buffers
  if original_is_virtual then
    semantic.apply_semantic_tokens(original_buf, modified_buf)
  end
  if modified_is_virtual then
    semantic.apply_semantic_tokens(modified_buf, original_buf)
  end

  -- Setup scrollbind synchronization (only if windows provided)
  if original_win and modified_win and vim.api.nvim_win_is_valid(original_win) and vim.api.nvim_win_is_valid(modified_win) then
    -- Save cursor position if we need to preserve it (on update)
    local saved_cursor = nil
    if not auto_scroll_to_first_hunk then
      saved_cursor = vim.api.nvim_win_get_cursor(modified_win)
    end

    -- Step 1: Cancel previous scrollbind
    vim.wo[original_win].scrollbind = false
    vim.wo[modified_win].scrollbind = false

    -- Step 2: ATOMIC - Reset both to line 1 AND re-enable scrollbind together
    -- This ensures scrollbind is established with proper baseline for filler lines
    vim.api.nvim_win_set_cursor(original_win, { 1, 0 })
    vim.api.nvim_win_set_cursor(modified_win, { 1, 0 })
    vim.wo[original_win].scrollbind = true
    vim.wo[modified_win].scrollbind = true

    -- Re-apply critical window options that might have been reset
    vim.wo[original_win].wrap = false
    vim.wo[modified_win].wrap = false

    -- Step 3a: On create, scroll to first change
    if auto_scroll_to_first_hunk and #lines_diff.changes > 0 then
      local first_change = lines_diff.changes[1]
      local target_line = first_change.original.start_line

      pcall(vim.api.nvim_win_set_cursor, original_win, { target_line, 0 })
      pcall(vim.api.nvim_win_set_cursor, modified_win, { target_line, 0 })

      if vim.api.nvim_win_is_valid(modified_win) then
        vim.api.nvim_set_current_win(modified_win)
        vim.cmd("normal! zz")
      end
    -- Step 3b: On update, restore saved cursor position
    elseif saved_cursor then
      pcall(vim.api.nvim_win_set_cursor, modified_win, saved_cursor)
      -- Sync original window to same line (scrollbind will handle column)
      pcall(vim.api.nvim_win_set_cursor, original_win, { saved_cursor[1], 0 })
    end
  end

  return lines_diff
end

-- Conflict mode rendering: Both buffers show diff against base with alignment
-- Left buffer (:3: theirs/incoming) and Right buffer (:2: ours/current)
-- Both show green highlights indicating changes from base (:1:)
-- Filler lines are inserted to align corresponding changes
-- @param original_buf number: Left buffer (incoming :3:)
-- @param modified_buf number: Right buffer (current :2:)
-- @param base_lines table: Base content (:1:)
-- @param original_lines table: Incoming content (:3:)
-- @param modified_lines table: Current content (:2:)
-- @param original_win number: Left window
-- @param modified_win number: Right window
-- @param auto_scroll_to_first_hunk boolean: Whether to scroll to first change
-- @return table: { base_to_original_diff, base_to_modified_diff }
function M.compute_and_render_conflict(original_buf, modified_buf, base_lines, original_lines, modified_lines, original_win, modified_win, auto_scroll_to_first_hunk)
  local diff_options = {
    max_computation_time_ms = config.options.diff.max_computation_time_ms,
  }

  -- Compute base -> original (incoming) diff
  local base_to_original_diff = diff_module.compute_diff(base_lines, original_lines, diff_options)
  if not base_to_original_diff then
    vim.notify("Failed to compute base->incoming diff", vim.log.levels.ERROR)
    return nil
  end

  -- Compute base -> modified (current) diff
  local base_to_modified_diff = diff_module.compute_diff(base_lines, modified_lines, diff_options)
  if not base_to_modified_diff then
    vim.notify("Failed to compute base->current diff", vim.log.levels.ERROR)
    return nil
  end

  -- Render merge view with alignment and filler lines
  local render_result = core.render_merge_view(original_buf, modified_buf, base_to_original_diff, base_to_modified_diff, base_lines, original_lines, modified_lines)

  -- Apply semantic tokens (both are virtual buffers in conflict mode)
  semantic.apply_semantic_tokens(original_buf, modified_buf)
  semantic.apply_semantic_tokens(modified_buf, original_buf)

  -- Setup window options with scrollbind (filler lines enable proper alignment)
  if original_win and modified_win and vim.api.nvim_win_is_valid(original_win) and vim.api.nvim_win_is_valid(modified_win) then
    vim.wo[original_win].wrap = false
    vim.wo[modified_win].wrap = false

    -- Reset scroll position and enable scrollbind
    vim.api.nvim_win_set_cursor(original_win, { 1, 0 })
    vim.api.nvim_win_set_cursor(modified_win, { 1, 0 })
    vim.wo[original_win].scrollbind = true
    vim.wo[modified_win].scrollbind = true

    -- Scroll to first change in either buffer
    if auto_scroll_to_first_hunk then
      local first_line = nil
      if #base_to_original_diff.changes > 0 then
        first_line = base_to_original_diff.changes[1].modified.start_line
      elseif #base_to_modified_diff.changes > 0 then
        first_line = base_to_modified_diff.changes[1].modified.start_line
      end

      if first_line then
        pcall(vim.api.nvim_win_set_cursor, original_win, { first_line, 0 })
        pcall(vim.api.nvim_win_set_cursor, modified_win, { first_line, 0 })
        if vim.api.nvim_win_is_valid(modified_win) then
          vim.api.nvim_set_current_win(modified_win)
          vim.cmd("normal! zz")
        end
      end
    end
  end

  return {
    base_to_original_diff = base_to_original_diff,
    base_to_modified_diff = base_to_modified_diff,
    conflict_blocks = render_result and render_result.conflict_blocks or {},
  }
end

-- Common logic: Setup auto-refresh for real file buffers
function M.setup_auto_refresh(original_buf, modified_buf, original_is_virtual, modified_is_virtual)
  local auto_refresh = require("codediff.ui.auto_refresh")

  if not original_is_virtual then
    auto_refresh.enable(original_buf)
  end

  if not modified_is_virtual then
    auto_refresh.enable(modified_buf)
  end
end

return M
