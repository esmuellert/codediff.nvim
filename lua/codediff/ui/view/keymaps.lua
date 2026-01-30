-- Keymaps setup for diff view
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local auto_refresh = require("codediff.ui.auto_refresh")
local config = require("codediff.config")

-- Centralized keymap setup for all diff view keymaps
-- This function sets up ALL keymaps in one place for better maintainability
function M.setup_all_keymaps(tabpage, original_bufnr, modified_bufnr, is_explorer_mode)
  local keymaps = config.options.keymaps.view

  -- Check if this is history mode
  local session = lifecycle.get_session(tabpage)
  local is_history_mode = session and session.mode == "history"

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
    local is_modified = current_buf == modified_bufnr
    local is_result = session.result_bufnr and current_buf == session.result_bufnr

    -- If cursor is in result buffer (conflict mode), use modified side line numbers
    -- but stay in current window
    if is_result then
      is_original = false
    -- If cursor is not in any diff buffer (e.g., in explorer/history), switch to modified window
    elseif not is_original and not is_modified then
      is_original = false -- Use modified side for line numbers
      local target_win = session.modified_win
      if target_win and vim.api.nvim_win_is_valid(target_win) then
        vim.api.nvim_set_current_win(target_win)
      else
        return
      end
    end

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
    local is_modified = current_buf == modified_bufnr
    local is_result = session.result_bufnr and current_buf == session.result_bufnr

    -- If cursor is in result buffer (conflict mode), use modified side line numbers
    -- but stay in current window
    if is_result then
      is_original = false
    -- If cursor is not in any diff buffer (e.g., in explorer/history), switch to modified window
    elseif not is_original and not is_modified then
      is_original = false -- Use modified side for line numbers
      local target_win = session.modified_win
      if target_win and vim.api.nvim_win_is_valid(target_win) then
        vim.api.nvim_set_current_win(target_win)
      else
        return
      end
    end

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

  -- Helper: Navigate to next file (works in both explorer and history mode)
  -- In single-file history mode, navigates commits instead
  local function navigate_next_file()
    local panel_obj = lifecycle.get_explorer(tabpage)
    if not panel_obj then
      return
    end
    if is_history_mode then
      local history = require("codediff.ui.history")
      if panel_obj.is_single_file_mode then
        history.navigate_next_commit(panel_obj)
      else
        history.navigate_next(panel_obj)
      end
    else
      local explorer = require("codediff.ui.explorer")
      explorer.navigate_next(panel_obj)
    end
  end

  -- Helper: Navigate to previous file (works in both explorer and history mode)
  -- In single-file history mode, navigates commits instead
  local function navigate_prev_file()
    local panel_obj = lifecycle.get_explorer(tabpage)
    if not panel_obj then
      return
    end
    if is_history_mode then
      local history = require("codediff.ui.history")
      if panel_obj.is_single_file_mode then
        history.navigate_prev_commit(panel_obj)
      else
        history.navigate_prev(panel_obj)
      end
    else
      local explorer = require("codediff.ui.explorer")
      explorer.navigate_prev(panel_obj)
    end
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

  -- Helper: Toggle stage/unstage for current file (tab-wide)
  -- Works in: explorer buffer, diff buffers (original/modified)
  -- Does nothing in: history buffer, other buffers
  local function toggle_stage()
    local current_buf = vim.api.nvim_get_current_buf()
    local explorer = lifecycle.get_explorer(tabpage)
    local session = lifecycle.get_session(tabpage)

    if not session then
      return
    end

    -- Only available in explorer mode with git
    if not is_explorer_mode then
      vim.notify("Stage/unstage only available in explorer mode", vim.log.levels.WARN)
      return
    end

    if not explorer or not explorer.git_root then
      vim.notify("Stage/unstage only available in git mode", vim.log.levels.WARN)
      return
    end

    -- Case 1: Cursor in explorer buffer
    if explorer.bufnr and current_buf == explorer.bufnr then
      -- Delegate to explorer action (handles files and directories)
      local explorer_module = require("codediff.ui.explorer")
      explorer_module.toggle_stage_entry(explorer, explorer.tree)
      return
    end

    -- Case 2: Cursor in diff buffers (original or modified)
    if current_buf == original_bufnr or current_buf == modified_bufnr then
      local file_path = explorer.current_file_path
      local group = explorer.current_file_group

      -- Guard: must have a current file selected
      if not file_path then
        vim.notify("No file selected", vim.log.levels.WARN)
        return
      end

      -- Guard: file must be stageable
      if not group or (group ~= "staged" and group ~= "unstaged" and group ~= "conflicts") then
        vim.notify("Current file cannot be staged/unstaged", vim.log.levels.WARN)
        return
      end

      local explorer_module = require("codediff.ui.explorer")
      explorer_module.toggle_stage_file(explorer.git_root, file_path, group)
      return
    end

    -- Case 3: Other buffers (history, etc.) - do nothing silently
  end

  -- Helper: Open the current real buffer in the previous tab (or create one before)
  local function open_in_prev_tab()
    local session = lifecycle.get_session(tabpage)
    if not session then
      return
    end

    local current_buf = vim.api.nvim_get_current_buf()
    local side = nil
    if current_buf == original_bufnr then
      side = "original"
    elseif current_buf == modified_bufnr then
      side = "modified"
    end

    -- Only operate on diff buffers; ignore explorer/history/result silently
    if not side then
      return
    end

    local is_virtual = (side == "original" and lifecycle.is_original_virtual(tabpage)) or (side == "modified" and lifecycle.is_modified_virtual(tabpage))
    if is_virtual then
      vim.notify("Current buffer is virtual; nothing to open in a tab", vim.log.levels.WARN)
      return
    end

    local buf_name = vim.api.nvim_buf_get_name(current_buf)
    if buf_name == "" then
      vim.notify("Buffer has no name; cannot open in previous tab", vim.log.levels.WARN)
      return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_tab = vim.api.nvim_get_current_tabpage()
    local tabs = vim.api.nvim_list_tabpages()

    local current_index = nil
    for i, tab in ipairs(tabs) do
      if tab == current_tab then
        current_index = i
        break
      end
    end

    local target_tab
    if current_index and current_index > 1 then
      target_tab = tabs[current_index - 1]
    else
      vim.cmd("tabnew")
      target_tab = vim.api.nvim_get_current_tabpage()
      vim.cmd("tabmove 0")
    end

    if vim.api.nvim_get_current_tabpage() ~= target_tab then
      vim.api.nvim_set_current_tabpage(target_tab)
    end

    local target_win = vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(target_win) then
      vim.notify("No valid window in target tab to open buffer", vim.log.levels.ERROR)
      return
    end

    local ok, err = pcall(vim.api.nvim_win_set_buf, target_win, current_buf)
    if not ok then
      vim.notify("Failed to open buffer in previous tab: " .. err, vim.log.levels.ERROR)
      return
    end

    pcall(vim.api.nvim_win_set_cursor, target_win, cursor)
  end

  -- ========================================================================
  -- Hunk-level staging (S, U)
  -- Generates a unified diff patch for the hunk under cursor and applies it
  -- to the git index via `git apply --cached --unidiff-zero`.
  -- Stage (S): applies the hunk's changes to the index (working → staged)
  -- Unstage (U): reverse-applies to remove the hunk from the index
  -- ========================================================================

  --- Build a minimal unified diff patch string for a single hunk.
  --- The patch has no context lines (used with --unidiff-zero).
  --- @param file_path string relative path from git root
  --- @param orig_lines string[] lines from the original (HEAD) buffer for this hunk
  --- @param mod_lines string[] lines from the modified (working/staged) buffer for this hunk
  --- @param orig_start number 1-based start line in original file
  --- @param mod_start number 1-based start line in modified file
  --- @return string patch valid unified diff patch
  local function build_hunk_patch(file_path, orig_lines, mod_lines, orig_start, mod_start)
    local orig_count = #orig_lines
    local mod_count = #mod_lines

    -- For pure insertions with 0 original lines, git expects start to be
    -- the line AFTER which content is inserted (0 if at very start)
    local hdr_orig_start = orig_count == 0 and (orig_start > 0 and orig_start - 1 or 0) or orig_start
    local hdr_mod_start = mod_count == 0 and (mod_start > 0 and mod_start - 1 or 0) or mod_start

    local parts = {
      string.format("--- a/%s", file_path),
      string.format("+++ b/%s", file_path),
      string.format("@@ -%d,%d +%d,%d @@", hdr_orig_start, orig_count, hdr_mod_start, mod_count),
    }

    for _, line in ipairs(orig_lines) do
      table.insert(parts, "-" .. line)
    end
    for _, line in ipairs(mod_lines) do
      table.insert(parts, "+" .. line)
    end

    -- Patch must end with a newline
    return table.concat(parts, "\n") .. "\n"
  end

  -- Helper: Stage hunk under cursor to git index
  local function stage_hunk()
    local session = lifecycle.get_session(tabpage)
    if not session or not session.git_root then
      vim.notify("Not in a git repository", vim.log.levels.WARN)
      return
    end

    local hunk, hunk_idx = find_hunk_at_cursor()
    if not hunk then
      vim.notify("No hunk at cursor position", vim.log.levels.WARN)
      return
    end

    -- Get the file path relative to git root
    local file_path = session.original_path or session.modified_path
    if not file_path or file_path == "" then
      vim.notify("No file path for staging", vim.log.levels.WARN)
      return
    end

    -- Read lines from both buffers for this hunk
    local orig_lines = vim.api.nvim_buf_get_lines(
      original_bufnr,
      hunk.original.start_line - 1,
      hunk.original.end_line - 1,
      false
    )
    local mod_lines = vim.api.nvim_buf_get_lines(
      modified_bufnr,
      hunk.modified.start_line - 1,
      hunk.modified.end_line - 1,
      false
    )

    local patch = build_hunk_patch(file_path, orig_lines, mod_lines,
      hunk.original.start_line, hunk.modified.start_line)

    -- Capture hunk count before async call (stored_diff_result may change)
    local total_hunks = session.stored_diff_result and #session.stored_diff_result.changes or 0
    local is_unstaged_view = session.modified_revision == nil

    local git = require('codediff.core.git')
    git.apply_patch(session.git_root, patch, false, function(err)
      if err then
        vim.notify("Failed to stage hunk: " .. err, vim.log.levels.ERROR)
        return
      end

      -- Refresh explorer to reflect staging change
      local explorer_obj = lifecycle.get_explorer(tabpage)
      if explorer_obj then
        local explorer = require('codediff.ui.explorer')
        explorer.refresh(explorer_obj)
      end

      if total_hunks == 1 and is_unstaged_view and explorer_obj and explorer_obj.on_file_select then
        -- Last unstaged hunk staged: switch to staged view
        explorer_obj.on_file_select({
          path = file_path,
          group = "staged",
          status = "M",
        })
        vim.notify("All hunks staged — switched to staged view", vim.log.levels.INFO)
      else
        vim.notify(string.format("Staged hunk %d", hunk_idx), vim.log.levels.INFO)

        -- Refresh diff view: reload virtual buffers and recompute diff
        -- For unstaged views where original was HEAD, switch to :0 (index)
        -- so the staged hunk disappears from the diff (matches VS Code behavior)
        local view = require('codediff.ui.view')
        local refresh_config = {
          mode = session.mode,
          git_root = session.git_root,
          original_path = session.original_path,
          modified_path = session.modified_path,
          original_revision = session.original_revision,
          modified_revision = session.modified_revision,
        }
        if is_unstaged_view and session.original_revision ~= ":0" then
          refresh_config.original_revision = ":0"
        end
        -- Save current window so view.update() doesn't move cursor
        -- (creating a new virtual buffer uses :edit! which switches window)
        local current_win = vim.api.nvim_get_current_win()
        view.update(tabpage, refresh_config, false)
        if vim.api.nvim_win_is_valid(current_win) then
          vim.api.nvim_set_current_win(current_win)
        end
      end
    end)
  end

  -- Helper: Unstage hunk under cursor from git index
  local function unstage_hunk()
    local session = lifecycle.get_session(tabpage)
    if not session or not session.git_root then
      vim.notify("Not in a git repository", vim.log.levels.WARN)
      return
    end

    local hunk, hunk_idx = find_hunk_at_cursor()
    if not hunk then
      vim.notify("No hunk at cursor position", vim.log.levels.WARN)
      return
    end

    local file_path = session.original_path or session.modified_path
    if not file_path or file_path == "" then
      vim.notify("No file path for unstaging", vim.log.levels.WARN)
      return
    end

    -- Read lines from both buffers for this hunk
    local orig_lines = vim.api.nvim_buf_get_lines(
      original_bufnr,
      hunk.original.start_line - 1,
      hunk.original.end_line - 1,
      false
    )
    local mod_lines = vim.api.nvim_buf_get_lines(
      modified_bufnr,
      hunk.modified.start_line - 1,
      hunk.modified.end_line - 1,
      false
    )

    local patch = build_hunk_patch(file_path, orig_lines, mod_lines,
      hunk.original.start_line, hunk.modified.start_line)

    -- Capture hunk count before async call (stored_diff_result may change)
    local total_hunks = session.stored_diff_result and #session.stored_diff_result.changes or 0
    local is_staged_view = session.modified_revision == ":0"

    local git = require('codediff.core.git')
    git.apply_patch(session.git_root, patch, true, function(err)
      if err then
        vim.notify("Failed to unstage hunk: " .. err, vim.log.levels.ERROR)
        return
      end

      -- Refresh explorer to reflect unstaging change
      local explorer_obj = lifecycle.get_explorer(tabpage)
      if explorer_obj then
        local explorer = require('codediff.ui.explorer')
        explorer.refresh(explorer_obj)
      end

      if total_hunks == 1 and is_staged_view and explorer_obj and explorer_obj.on_file_select then
        -- Last staged hunk unstaged: switch to unstaged view
        explorer_obj.on_file_select({
          path = file_path,
          group = "unstaged",
          status = "M",
        })
        vim.notify("All hunks unstaged — switched to unstaged view", vim.log.levels.INFO)
      else
        vim.notify(string.format("Unstaged hunk %d", hunk_idx), vim.log.levels.INFO)

        -- Refresh diff view: reload virtual buffers and recompute diff
        local view = require('codediff.ui.view')
        local current_win = vim.api.nvim_get_current_win()
        view.update(tabpage, {
          mode = session.mode,
          git_root = session.git_root,
          original_path = session.original_path,
          modified_path = session.modified_path,
          original_revision = session.original_revision,
          modified_revision = session.modified_revision,
        }, false)
        if vim.api.nvim_win_is_valid(current_win) then
          vim.api.nvim_set_current_win(current_win)
        end
      end
    end)
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

  -- Diff get/put (do, dp) - like vimdiff
  if keymaps.diff_get then
    lifecycle.set_tab_keymap(tabpage, "n", keymaps.diff_get, diff_get, { desc = "Get change from other buffer" })
  end
  if keymaps.diff_put then
    lifecycle.set_tab_keymap(tabpage, "n", keymaps.diff_put, diff_put, { desc = "Put change to other buffer" })
  end
  if keymaps.open_in_prev_tab then
    lifecycle.set_tab_keymap(tabpage, "n", keymaps.open_in_prev_tab, open_in_prev_tab, { desc = "Open buffer in previous tab" })
  end

  -- Toggle stage/unstage (- key) - only in explorer mode
  -- Support legacy config: keymaps.explorer.toggle_stage (deprecated)
  if is_explorer_mode then
    local toggle_stage_key = keymaps.toggle_stage
    local explorer_keymaps = config.options.keymaps.explorer or {}

    -- Fallback to deprecated explorer.toggle_stage if view.toggle_stage not set
    if not toggle_stage_key and explorer_keymaps.toggle_stage then
      toggle_stage_key = explorer_keymaps.toggle_stage
      vim.schedule(function()
        vim.notify("[codediff] keymaps.explorer.toggle_stage is deprecated. Please use keymaps.view.toggle_stage instead.", vim.log.levels.WARN)
      end)
    end

    if toggle_stage_key then
      lifecycle.set_tab_keymap(tabpage, "n", toggle_stage_key, toggle_stage, { desc = "Toggle stage/unstage" })
    end
  end

  -- File navigation (]f, [f) - works in both explorer and history mode
  if is_explorer_mode or is_history_mode then
    if keymaps.next_file then
      lifecycle.set_tab_keymap(tabpage, "n", keymaps.next_file, navigate_next_file, { desc = "Next file" })
    end
    if keymaps.prev_file then
      lifecycle.set_tab_keymap(tabpage, "n", keymaps.prev_file, navigate_prev_file, { desc = "Previous file" })
    end
  end

  -- Hunk-level staging (S, U) - stage/unstage individual hunks via git apply
  if keymaps.stage_hunk then
    lifecycle.set_tab_keymap(tabpage, 'n', keymaps.stage_hunk, stage_hunk, { desc = 'Stage hunk under cursor' })
  end
  if keymaps.unstage_hunk then
    lifecycle.set_tab_keymap(tabpage, 'n', keymaps.unstage_hunk, unstage_hunk, { desc = 'Unstage hunk under cursor' })
  end
end

return M
