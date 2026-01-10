-- Conflict result window setup for merge tool
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local auto_refresh = require("codediff.ui.auto_refresh")

-- Common logic: Setup conflict result window at bottom
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
  local abs_path = session_config.git_root .. "/" .. session_config.original_path
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
    if vim.api.nvim_win_is_valid(modified_win) then
      vim.api.nvim_set_current_win(modified_win)
    end
    vim.cmd("belowright split")
    result_win = vim.api.nvim_get_current_win()

    -- Move original window to be a vertical split with modified
    vim.fn.win_splitmove(original_win, modified_win, { vertical = true, rightbelow = false })

    -- Set result window height (30% of available height or minimum 10 lines)
    local total_height = vim.o.lines
    local result_height = math.max(10, math.floor(total_height * 0.3))
    vim.api.nvim_win_set_height(result_win, result_height)
  end

  -- Load real file buffer in result window
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

  -- Reset buffer content to BASE (only if buffer has conflict markers)
  local current_content = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)
  local has_conflict_markers = false
  for _, line in ipairs(current_content) do
    if line:match("^<<<<<<<") or line:match("^=======") or line:match("^>>>>>>>") then
      has_conflict_markers = true
      break
    end
  end

  if has_conflict_markers then
    vim.api.nvim_buf_set_lines(result_bufnr, 0, -1, false, base_lines)
    vim.bo[result_bufnr].modified = true
  end

  -- Set window options for result
  vim.wo[result_win].wrap = false
  vim.wo[result_win].cursorline = true
  vim.wo[result_win].winbar = ""

  -- Enable scrollbind for result window
  vim.api.nvim_win_set_cursor(result_win, { 1, 0 })
  vim.wo[result_win].scrollbind = true

  -- Update lifecycle with result buffer/window
  lifecycle.set_result(tabpage, result_bufnr, result_win)
  lifecycle.set_result_base_lines(tabpage, base_lines)
  lifecycle.set_conflict_blocks(tabpage, conflict_diffs.conflict_blocks)
  lifecycle.track_conflict_file(tabpage, abs_path)

  -- Enable auto-refresh for result buffer
  auto_refresh.enable_for_result(result_bufnr)

  -- Initialize conflict tracking (keymaps setup separately after setup_all_keymaps)
  local conflict = require("codediff.ui.conflict")
  conflict.initialize_tracking(result_bufnr, conflict_diffs.conflict_blocks)

  -- Setup autocmd to refresh signs when result buffer changes (event-driven approach)
  conflict.setup_sign_refresh_autocmd(tabpage, result_bufnr)

  -- Initialize all conflict signs (uses refresh_all_conflict_signs for centralized logic)
  local session = lifecycle.get_session(tabpage)
  if session then
    conflict.refresh_all_conflict_signs(session)
  end

  -- Return focus to modified window
  if vim.api.nvim_win_is_valid(modified_win) then
    vim.api.nvim_set_current_win(modified_win)
  end

  return true
end

return M
