-- Keymaps setup for diff view
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local auto_refresh = require("codediff.ui.auto_refresh")
local config = require("codediff.config")

-- Centralized keymap setup for all diff view keymaps
-- This function sets up ALL keymaps in one place for better maintainability
function M.setup_all_keymaps(tabpage, original_bufnr, modified_bufnr, is_explorer_mode)
  local keymaps = config.options.keymaps.view

  -- Helper: Navigate to next hunk
  local function navigate_next_hunk()
    local session = lifecycle.get_session(tabpage)
    if not session or not session.stored_diff_result then
      return
    end
    local diff_result = session.stored_diff_result
    if #diff_result.changes == 0 then
      return
    end

    local current_buf = vim.api.nvim_get_current_buf()
    local is_original = current_buf == original_bufnr
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]

    -- Find next hunk after current line
    for i, mapping in ipairs(diff_result.changes) do
      local target_line = is_original and mapping.original.start_line or mapping.modified.start_line
      if target_line > current_line then
        pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
        vim.api.nvim_echo({ { string.format("Hunk %d of %d", i, #diff_result.changes), "None" } }, false, {})
        return
      end
    end

    -- Wrap around to first hunk
    local first_hunk = diff_result.changes[1]
    local target_line = is_original and first_hunk.original.start_line or first_hunk.modified.start_line
    pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
    vim.api.nvim_echo({ { string.format("Hunk 1 of %d", #diff_result.changes), "None" } }, false, {})
  end

  -- Helper: Navigate to previous hunk
  local function navigate_prev_hunk()
    local session = lifecycle.get_session(tabpage)
    if not session or not session.stored_diff_result then
      return
    end
    local diff_result = session.stored_diff_result
    if #diff_result.changes == 0 then
      return
    end

    local current_buf = vim.api.nvim_get_current_buf()
    local is_original = current_buf == original_bufnr
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]

    -- Find previous hunk before current line (search backwards)
    for i = #diff_result.changes, 1, -1 do
      local mapping = diff_result.changes[i]
      local target_line = is_original and mapping.original.start_line or mapping.modified.start_line
      if target_line < current_line then
        pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
        vim.api.nvim_echo({ { string.format("Hunk %d of %d", i, #diff_result.changes), "None" } }, false, {})
        return
      end
    end

    -- Wrap around to last hunk
    local last_hunk = diff_result.changes[#diff_result.changes]
    local target_line = is_original and last_hunk.original.start_line or last_hunk.modified.start_line
    pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
    vim.api.nvim_echo({ { string.format("Hunk %d of %d", #diff_result.changes, #diff_result.changes), "None" } }, false, {})
  end

  -- Helper: Navigate to next file (explorer mode only)
  local function navigate_next_file()
    local explorer_obj = lifecycle.get_explorer(tabpage)
    if not explorer_obj then
      vim.notify("No explorer found for this tab", vim.log.levels.WARN)
      return
    end
    local explorer = require("codediff.ui.explorer")
    explorer.navigate_next(explorer_obj)
  end

  -- Helper: Navigate to previous file (explorer mode only)
  local function navigate_prev_file()
    local explorer_obj = lifecycle.get_explorer(tabpage)
    if not explorer_obj then
      vim.notify("No explorer found for this tab", vim.log.levels.WARN)
      return
    end
    local explorer = require("codediff.ui.explorer")
    explorer.navigate_prev(explorer_obj)
  end

  -- Helper: Quit diff view
  local function quit_diff()
    -- Check for unsaved conflict files before closing
    if not lifecycle.confirm_close_with_unsaved(tabpage) then
      return -- User cancelled
    end
    vim.cmd("tabclose")
  end

  -- Helper: Toggle explorer visibility (explorer mode only)
  local function toggle_explorer()
    local explorer_obj = lifecycle.get_explorer(tabpage)
    if not explorer_obj then
      vim.notify("No explorer found for this tab", vim.log.levels.WARN)
      return
    end
    local explorer = require("codediff.ui.explorer")
    explorer.toggle_visibility(explorer_obj)
  end

  -- Helper: Find hunk at cursor position
  -- Returns the hunk and its index, or nil if cursor is not in a hunk
  local function find_hunk_at_cursor()
    local session = lifecycle.get_session(tabpage)
    if not session or not session.stored_diff_result then
      return nil, nil
    end
    local diff_result = session.stored_diff_result
    if #diff_result.changes == 0 then
      return nil, nil
    end

    local current_buf = vim.api.nvim_get_current_buf()
    local is_original = current_buf == original_bufnr
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]

    for i, mapping in ipairs(diff_result.changes) do
      local start_line = is_original and mapping.original.start_line or mapping.modified.start_line
      local end_line = is_original and mapping.original.end_line or mapping.modified.end_line
      -- Check if cursor is within this hunk (end_line is exclusive)
      if current_line >= start_line and current_line < end_line then
        return mapping, i
      end
      -- Also match if it's a deletion (empty range) and cursor is at start
      if start_line == end_line and current_line == start_line then
        return mapping, i
      end
    end
    return nil, nil
  end

  -- Helper: Diff get - obtain change from other buffer to current buffer
  local function diff_get()
    local session = lifecycle.get_session(tabpage)
    if not session then
      return
    end

    local current_buf = vim.api.nvim_get_current_buf()
    local is_original = current_buf == original_bufnr
    local target_buf = current_buf
    local source_buf = is_original and modified_bufnr or original_bufnr

    -- Check if target buffer is modifiable
    if not vim.bo[target_buf].modifiable then
      vim.notify("Buffer is not modifiable", vim.log.levels.WARN)
      return
    end

    local hunk, hunk_idx = find_hunk_at_cursor()
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
    auto_refresh.trigger(target_buf)

    vim.api.nvim_echo({ { string.format("Obtained hunk %d", hunk_idx), "None" } }, false, {})
  end

  -- Helper: Diff put - put change from current buffer to other buffer
  local function diff_put()
    local session = lifecycle.get_session(tabpage)
    if not session then
      return
    end

    local current_buf = vim.api.nvim_get_current_buf()
    local is_original = current_buf == original_bufnr
    local source_buf = current_buf
    local target_buf = is_original and modified_bufnr or original_bufnr

    -- Check if target buffer is modifiable
    if not vim.bo[target_buf].modifiable then
      vim.notify("Target buffer is not modifiable", vim.log.levels.WARN)
      return
    end

    local hunk, hunk_idx = find_hunk_at_cursor()
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
    auto_refresh.trigger(target_buf)

    vim.api.nvim_echo({ { string.format("Put hunk %d", hunk_idx), "None" } }, false, {})
  end

  -- ========================================================================
  -- Bind all keymaps using unified API (one place for all keymaps!)
  -- ========================================================================

  -- Quit keymap (q)
  if keymaps.quit then
    lifecycle.set_tab_keymap(tabpage, "n", keymaps.quit, quit_diff, { desc = "Close codediff tab" })
  end

  -- Hunk navigation (]c, [c)
  if keymaps.next_hunk then
    lifecycle.set_tab_keymap(tabpage, "n", keymaps.next_hunk, navigate_next_hunk, { desc = "Next hunk" })
  end
  if keymaps.prev_hunk then
    lifecycle.set_tab_keymap(tabpage, "n", keymaps.prev_hunk, navigate_prev_hunk, { desc = "Previous hunk" })
  end

  -- Explorer toggle (e) - only in explorer mode
  if is_explorer_mode and keymaps.toggle_explorer then
    lifecycle.set_tab_keymap(tabpage, "n", keymaps.toggle_explorer, toggle_explorer, { desc = "Toggle explorer visibility" })
  end

  -- File navigation (]f, [f) - only in explorer mode
  if is_explorer_mode then
    if keymaps.next_file then
      lifecycle.set_tab_keymap(tabpage, "n", keymaps.next_file, navigate_next_file, { desc = "Next file in explorer" })
    end
    if keymaps.prev_file then
      lifecycle.set_tab_keymap(tabpage, "n", keymaps.prev_file, navigate_prev_file, { desc = "Previous file in explorer" })
    end
  end

  -- Diff get/put (do, dp) - like vimdiff
  if keymaps.diff_get then
    lifecycle.set_tab_keymap(tabpage, "n", keymaps.diff_get, diff_get, { desc = "Get change from other buffer" })
  end
  if keymaps.diff_put then
    lifecycle.set_tab_keymap(tabpage, "n", keymaps.diff_put, diff_put, { desc = "Put change to other buffer" })
  end
end

return M
