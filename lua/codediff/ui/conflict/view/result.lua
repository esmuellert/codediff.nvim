-- Conflict result window setup for merge tool
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local auto_refresh = require("codediff.ui.auto_refresh")
local config = require("codediff.config")
local layout = require("codediff.ui.layout")

--- Create result window at the bottom (default layout)
--- Layout: [incoming | current] on top, [result] at bottom
--- @param modified_win number
--- @param original_win number
--- @return number result_win
local function create_bottom_layout(modified_win, original_win)
  local scratch = vim.api.nvim_create_buf(false, true)
  local result_win = vim.api.nvim_open_win(scratch, true, { split = "below", win = modified_win })

  vim.fn.win_splitmove(original_win, modified_win, { vertical = true, rightbelow = false })

  return result_win
end

--- Create result window in the center (three vertical panes side-by-side)
--- Layout: [incoming | result | current] all side-by-side
--- @param modified_win number
--- @param original_win number
--- @return number result_win
local function create_center_layout(modified_win, original_win)
  local orig_col = vim.api.nvim_win_get_position(original_win)[2]
  local mod_col = vim.api.nvim_win_get_position(modified_win)[2]
  local left_win = orig_col <= mod_col and original_win or modified_win

  local scratch = vim.api.nvim_create_buf(false, true)
  local result_win = vim.api.nvim_open_win(scratch, true, { split = "right", win = left_win })

  return result_win
end

-- Common logic: Setup conflict result window
-- Creates the result window layout and loads the real file with BASE content
-- @param tabpage number: Current tabpage
-- @param session_config SessionConfig: Session configuration
-- @param original_win number: Original (left) window
-- @param modified_win number: Modified (right) window
-- @param base_lines table: BASE content lines
-- @param conflict_diffs table: Conflict diff results
-- @param is_update boolean: true if updating existing view (may reuse result window)
-- @return boolean: success
function M.setup_conflict_result_window(tabpage, session_config, original_win, modified_win, base_lines, conflict_diffs, is_update)
  local abs_path = session_config.original.absolute
  local result_win, result_bufnr

  -- Check if result window already exists (only in update mode)
  if is_update then
    local existing_result_bufnr, existing_result_win = lifecycle.get_result(tabpage)
    if existing_result_win and vim.api.nvim_win_is_valid(existing_result_win) then
      result_win = existing_result_win
      vim.api.nvim_set_current_win(result_win)
    end
  end

  -- Create result window if it doesn't exist
  if not result_win then
    local position = config.options.diff.conflict_result_position
    if position == "center" then
      result_win = create_center_layout(modified_win, original_win)
    else
      result_win = create_bottom_layout(modified_win, original_win)
    end
  end

  -- Load real file buffer in result window
  -- `:edit` acts on the current window and fails with E37 when the buffer it
  -- would abandon has unsaved changes -- which the result buffer always has
  -- once auto-merged content is applied. Window creation can also leave a
  -- different window current (win_splitmove). Pin the result window and park a
  -- throwaway scratch in it first, so the edit can never be refused. The real
  -- buffer is only hidden, so in-progress merge edits survive.
  if vim.api.nvim_win_is_valid(result_win) then
    vim.api.nvim_set_current_win(result_win)
    if vim.bo[vim.api.nvim_get_current_buf()].modified then
      vim.api.nvim_win_set_buf(result_win, vim.api.nvim_create_buf(false, true))
    end
  end

  -- Use silent and swapfile handling to avoid prompts
  local old_shortmess = vim.o.shortmess
  vim.o.shortmess = old_shortmess .. "A"
  local ok, err = pcall(vim.cmd, "silent edit " .. vim.fn.fnameescape(abs_path))
  vim.o.shortmess = old_shortmess

  if not ok then
    vim.notify("Failed to open result file: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  result_bufnr = vim.api.nvim_get_current_buf()

  -- Compute the auto-merged result: BASE + every non-conflicting change from
  -- both sides applied. Only true two-sided conflicts remain as BASE for the
  -- user to resolve. This matches VSCode's MergeEditorModel.computeAutoMergedResult.
  -- conflict_diffs.conflict_blocks (from compute_merge_fillers_and_conflicts) is
  -- the visual filler list for the side panes; the Result-buffer-oriented blocks
  -- (with result_range) come from compute_auto_merged_result.
  local merge_alignment = require("codediff.ui.conflict.merge")
  local result_lines, result_conflict_blocks = merge_alignment.compute_auto_merged_result(
    conflict_diffs.base_to_original_diff,
    conflict_diffs.base_to_modified_diff,
    base_lines,
    conflict_diffs.original_lines,
    conflict_diffs.modified_lines
  )

  -- Replace the result buffer (which currently contains the raw file with
  -- `<<<<<<<`/`=======`/`>>>>>>>` markers) with the auto-merged content.
  -- We always replace in the conflict path so the markers never persist into
  -- a manual save.
  vim.api.nvim_buf_set_lines(result_bufnr, 0, -1, false, result_lines)
  vim.bo[result_bufnr].modified = true

  -- Set window options for result
  vim.wo[result_win].wrap = false
  vim.wo[result_win].cursorline = true

  -- Enable native scrollbind for the result pane as the third bound window.
  vim.api.nvim_win_set_cursor(result_win, { 1, 0 })
  vim.wo[result_win].scrollbind = true

  -- Update lifecycle with result buffer/window FIRST
  -- (This must happen before setting winbar so ensure_no_winbar knows we're in conflict mode)
  lifecycle.set_result(tabpage, result_bufnr, result_win)
  -- result_base_lines is the seed of the Result buffer (the auto-merged
  -- content), used by is_block_active to decide whether a conflict region is
  -- still in its initial unresolved state. merge_base_lines keeps the true
  -- merge base (stage :1) for operations that need merge-base coordinates
  -- such as accept_both's smart-combine and discard.
  lifecycle.set_result_base_lines(tabpage, result_lines)
  lifecycle.set_merge_base_lines(tabpage, base_lines)
  lifecycle.set_conflict_blocks(tabpage, result_conflict_blocks)
  lifecycle.track_conflict_file(tabpage, abs_path)

  -- Arrange all windows now that lifecycle knows about result_win
  layout.arrange(tabpage)

  -- Now set winbar titles for conflict windows based on conflict_ours_position
  -- (After set_result so ensure_no_winbar can detect conflict mode)
  vim.wo[result_win].winbar = " Result"
  local ours_position = config.options.diff.conflict_ours_position
  if vim.api.nvim_win_is_valid(original_win) then
    if ours_position == "left" then
      vim.wo[original_win].winbar = " Ours (Current)"
    else
      vim.wo[original_win].winbar = " Theirs (Incoming)"
    end
  end
  if vim.api.nvim_win_is_valid(modified_win) then
    if ours_position == "left" then
      vim.wo[modified_win].winbar = " Theirs (Incoming)"
    else
      vim.wo[modified_win].winbar = " Ours (Current)"
    end
  end

  -- Enable auto-refresh for result buffer
  auto_refresh.enable_for_result(result_bufnr)

  -- Initialize conflict tracking (keymaps setup separately after setup_all_keymaps)
  local conflict = require("codediff.ui.conflict")
  conflict.initialize_tracking(result_bufnr, conflict_diffs.conflict_blocks)
  conflict.attach_gutter(original_win, modified_win)

  -- Setup autocmd to refresh markers when the result buffer changes.
  conflict.setup_refresh_autocmd(tabpage, result_bufnr)

  -- Initialize all conflict markers through the centralized renderer.
  local session = lifecycle.get_session(tabpage)
  if session then
    conflict.refresh(session)
  end

  -- Return focus to modified window
  if vim.api.nvim_win_is_valid(modified_win) then
    vim.api.nvim_set_current_win(modified_win)
  end

  return true
end

return M
