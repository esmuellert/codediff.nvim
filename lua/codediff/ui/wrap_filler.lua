-- Wrap-aware filler line calculation module
-- This module calculates extra filler lines needed when wrap mode is enabled
-- to keep original and modified diff views aligned at each logical line boundary.
--
-- The algorithm:
-- 1. For each line in both buffers, calculate how many visual lines it occupies
--    based on the window width and display width of the text
-- 2. At each corresponding line pair, calculate the difference in visual lines
-- 3. Insert filler lines on the side with fewer visual lines to maintain alignment
--
-- This module is designed to be triggered:
-- - On initial render when wrap mode is enabled
-- - On window resize (width change)
-- - On buffer content change (re-render)
--
-- Note: This module uses "original" and "modified" terminology to match the diff
-- structure. The actual window positions (left/right) are determined by config.

local M = {}

local ns_wrap_filler = vim.api.nvim_create_namespace("codediff_wrap_filler")

-- Export the namespace for external access
M.ns_wrap_filler = ns_wrap_filler

-- Calculate the display width of a string (handles multi-byte and wide chars)
-- Uses vim.fn.strdisplaywidth which properly handles:
-- - Multi-byte UTF-8 characters
-- - Double-width CJK characters
-- - Emoji (though width can vary by terminal)
-- - Tab characters (expands based on tabstop)
---@param str string The string to measure
---@return number Display width in columns
local function display_width(str)
  if not str or str == "" then
    return 0
  end
  return vim.fn.strdisplaywidth(str)
end

-- Calculate how many visual lines a string will occupy when wrapped
---@param str string The line content
---@param width number The window width in columns
---@return number Number of visual lines (minimum 1)
local function calculate_visual_lines(str, width)
  if width <= 0 then
    return 1
  end

  local dw = display_width(str)
  if dw == 0 then
    return 1 -- Empty line still takes 1 visual line
  end

  -- Ceiling division: how many lines of 'width' columns needed
  return math.ceil(dw / width)
end

-- Calculate wrap filler lines for a pair of buffers
-- This is the main entry point for wrap-aware filler calculation
--
-- The algorithm processes lines in pairs based on the diff mapping:
-- - For unchanged regions: lines correspond 1:1, add fillers to compensate for wrap differences
-- - For changed regions: the existing diff filler logic handles line count alignment,
--   and we add additional fillers for wrap differences within the change
--
---@param original_lines string[] Lines from original buffer
---@param modified_lines string[] Lines from modified buffer
---@param lines_diff table The diff result with changes array
---@param original_width number Width of original window in columns
---@param modified_width number Width of modified window in columns
---@return table fillers Array of {buffer="original"|"modified", after_line=number, count=number}
function M.calculate_wrap_fillers(original_lines, modified_lines, lines_diff, original_width, modified_width)
  local fillers = {}

  -- Track current position in each buffer (1-based line numbers)
  local orig_pos = 1
  local mod_pos = 1

  -- Helper to add filler
  local function add_filler(buffer, after_line, count)
    if count > 0 and after_line > 0 then
      table.insert(fillers, {
        buffer = buffer,
        after_line = after_line,
        count = count,
      })
    end
  end

  -- Process each change mapping
  for _, mapping in ipairs(lines_diff.changes) do
    local orig_start = mapping.original.start_line
    local orig_end = mapping.original.end_line
    local mod_start = mapping.modified.start_line
    local mod_end = mapping.modified.end_line

    -- Process unchanged lines before this change
    -- These lines correspond 1:1 between original and modified
    while orig_pos < orig_start and mod_pos < mod_start do
      local orig_line = original_lines[orig_pos] or ""
      local mod_line = modified_lines[mod_pos] or ""

      local orig_visual = calculate_visual_lines(orig_line, original_width)
      local mod_visual = calculate_visual_lines(mod_line, modified_width)

      local diff = orig_visual - mod_visual

      if diff > 0 then
        -- Original has more visual lines, add filler to modified
        add_filler("modified", mod_pos, diff)
      elseif diff < 0 then
        -- Modified has more visual lines, add filler to original
        add_filler("original", orig_pos, -diff)
      end

      orig_pos = orig_pos + 1
      mod_pos = mod_pos + 1
    end

    -- Now process the changed region
    -- The existing diff filler logic (core.lua calculate_fillers) handles LINE count differences.
    -- We need to handle additional VISUAL line differences due to wrapping.
    
    local orig_line_count = orig_end - orig_start
    local mod_line_count = mod_end - mod_start

    if orig_line_count > 0 and mod_line_count > 0 then
      -- Both sides have lines - this is a modification, not pure insert/delete
      -- Calculate total visual lines on each side
      local orig_change_visual = 0
      local mod_change_visual = 0

      for i = orig_start, orig_end - 1 do
        orig_change_visual = orig_change_visual + calculate_visual_lines(original_lines[i] or "", original_width)
      end

      for i = mod_start, mod_end - 1 do
        mod_change_visual = mod_change_visual + calculate_visual_lines(modified_lines[i] or "", modified_width)
      end

      -- Extra visual lines beyond basic line count
      local orig_extra = orig_change_visual - orig_line_count
      local mod_extra = mod_change_visual - mod_line_count

      local extra_diff = orig_extra - mod_extra

      if extra_diff > 0 then
        -- Original has more extra visual lines, add filler to modified after its change region
        add_filler("modified", mod_end - 1, extra_diff)
      elseif extra_diff < 0 then
        -- Modified has more extra visual lines, add filler to original after its change region
        add_filler("original", orig_end - 1, -extra_diff)
      end
    elseif orig_line_count == 0 and mod_line_count > 0 then
      -- Pure insertion: only modified has lines
      -- The existing filler adds `mod_line_count` fillers to original
      -- We need to add extra fillers for any wrapping on the modified side
      local mod_change_visual = 0
      for i = mod_start, mod_end - 1 do
        mod_change_visual = mod_change_visual + calculate_visual_lines(modified_lines[i] or "", modified_width)
      end
      local extra = mod_change_visual - mod_line_count
      if extra > 0 then
        -- Add extra fillers to original, placed before the insertion point
        local filler_line = orig_start > 1 and (orig_start - 1) or 1
        add_filler("original", filler_line, extra)
      end
    elseif mod_line_count == 0 and orig_line_count > 0 then
      -- Pure deletion: only original has lines
      -- The existing filler adds `orig_line_count` fillers to modified
      -- We need to add extra fillers for any wrapping on the original side
      local orig_change_visual = 0
      for i = orig_start, orig_end - 1 do
        orig_change_visual = orig_change_visual + calculate_visual_lines(original_lines[i] or "", original_width)
      end
      local extra = orig_change_visual - orig_line_count
      if extra > 0 then
        -- Add extra fillers to modified, placed before the deletion point
        local filler_line = mod_start > 1 and (mod_start - 1) or 1
        add_filler("modified", filler_line, extra)
      end
    end

    -- Update positions to after the change
    orig_pos = orig_end
    mod_pos = mod_end
  end

  -- Process remaining unchanged lines after all changes
  while orig_pos <= #original_lines and mod_pos <= #modified_lines do
    local orig_line = original_lines[orig_pos] or ""
    local mod_line = modified_lines[mod_pos] or ""

    local orig_visual = calculate_visual_lines(orig_line, original_width)
    local mod_visual = calculate_visual_lines(mod_line, modified_width)

    local diff = orig_visual - mod_visual

    if diff > 0 then
      add_filler("modified", mod_pos, diff)
    elseif diff < 0 then
      add_filler("original", orig_pos, -diff)
    end

    orig_pos = orig_pos + 1
    mod_pos = mod_pos + 1
  end

  return fillers
end

-- Insert wrap filler lines as virtual lines (extmarks)
---@param bufnr number Buffer number
---@param after_line number 1-based line number to insert after
---@param count number Number of filler lines to insert
local function insert_wrap_filler_lines(bufnr, after_line, count)
  if count <= 0 then
    return
  end

  -- Convert to 0-based index
  local line_idx = after_line - 1
  if line_idx < 0 then
    line_idx = 0
  end

  -- Create virtual lines content
  local virt_lines = {}
  local filler_text = string.rep("~", 500)

  for _ = 1, count do
    table.insert(virt_lines, { { filler_text, "CodeDiffFiller" } })
  end

  vim.api.nvim_buf_set_extmark(bufnr, ns_wrap_filler, line_idx, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
  })
end

-- Clear all wrap filler extmarks from a buffer
---@param bufnr number Buffer number
function M.clear_wrap_fillers(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns_wrap_filler, 0, -1)
  end
end

-- Apply wrap fillers to both buffers
-- This is the main rendering entry point
---@param original_bufnr number Original buffer number
---@param modified_bufnr number Modified buffer number
---@param original_lines string[] Lines from original buffer
---@param modified_lines string[] Lines from modified buffer
---@param lines_diff table The diff result
---@param original_win number Original window handle
---@param modified_win number Modified window handle
---@return table stats Statistics about applied fillers
function M.apply_wrap_fillers(original_bufnr, modified_bufnr, original_lines, modified_lines, lines_diff, original_win, modified_win)
  -- Clear existing wrap fillers
  M.clear_wrap_fillers(original_bufnr)
  M.clear_wrap_fillers(modified_bufnr)

  -- Get window widths
  local original_width = vim.api.nvim_win_get_width(original_win)
  local modified_width = vim.api.nvim_win_get_width(modified_win)

  -- Account for line number column, sign column, fold column, etc.
  -- Use textoff to get the actual text area width
  local original_textoff = vim.fn.getwininfo(original_win)[1].textoff or 0
  local modified_textoff = vim.fn.getwininfo(modified_win)[1].textoff or 0

  local original_text_width = original_width - original_textoff
  local modified_text_width = modified_width - modified_textoff

  -- Calculate wrap fillers
  local fillers = M.calculate_wrap_fillers(original_lines, modified_lines, lines_diff, original_text_width, modified_text_width)

  -- Apply fillers
  local original_filler_count = 0
  local modified_filler_count = 0

  for _, filler in ipairs(fillers) do
    if filler.buffer == "original" then
      insert_wrap_filler_lines(original_bufnr, filler.after_line, filler.count)
      original_filler_count = original_filler_count + filler.count
    else
      insert_wrap_filler_lines(modified_bufnr, filler.after_line, filler.count)
      modified_filler_count = modified_filler_count + filler.count
    end
  end

  return {
    original_fillers = original_filler_count,
    modified_fillers = modified_filler_count,
    total_fillers = #fillers,
  }
end

-- Setup window resize autocmd for a diff session
-- This will recalculate wrap fillers when window width changes
---@param tabpage number Tabpage handle
---@param original_bufnr number Original buffer number
---@param modified_bufnr number Modified buffer number
---@param original_win number Original window handle
---@param modified_win number Modified window handle
---@param get_state_fn function Function to get current diff state (lines, diff result)
function M.setup_resize_handler(tabpage, original_bufnr, modified_bufnr, original_win, modified_win, get_state_fn)
  local group = vim.api.nvim_create_augroup("CodeDiffWrapFiller_" .. tabpage, { clear = true })

  -- Track last known widths to avoid unnecessary recalculations
  local last_original_width = vim.api.nvim_win_is_valid(original_win) and vim.api.nvim_win_get_width(original_win) or 0
  local last_modified_width = vim.api.nvim_win_is_valid(modified_win) and vim.api.nvim_win_get_width(modified_win) or 0

  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      -- Check if our windows are still valid
      if not vim.api.nvim_win_is_valid(original_win) or not vim.api.nvim_win_is_valid(modified_win) then
        -- Clean up the autocmd group
        pcall(vim.api.nvim_del_augroup_by_id, group)
        return
      end

      -- Check if width changed
      local new_original_width = vim.api.nvim_win_get_width(original_win)
      local new_modified_width = vim.api.nvim_win_get_width(modified_win)

      if new_original_width == last_original_width and new_modified_width == last_modified_width then
        return -- No change
      end

      last_original_width = new_original_width
      last_modified_width = new_modified_width

      -- Get current state and recalculate
      local state = get_state_fn()
      if state and state.original_lines and state.modified_lines and state.lines_diff then
        M.apply_wrap_fillers(
          original_bufnr,
          modified_bufnr,
          state.original_lines,
          state.modified_lines,
          state.lines_diff,
          original_win,
          modified_win
        )
      end
    end,
  })

  return group
end

-- Cleanup function to remove resize handler
---@param tabpage number Tabpage handle
function M.cleanup_resize_handler(tabpage)
  pcall(vim.api.nvim_del_augroup_by_name, "CodeDiffWrapFiller_" .. tabpage)
end

return M
