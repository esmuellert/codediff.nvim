-- Temporarily align a moved code block with its counterpart in the other pane,
-- restoring both views once the cursor leaves the block.

local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local render = require("codediff.ui.view.render")

function M.align_move(ctx)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session or not session.stored_diff_result or not session.stored_diff_result.moves then
    return
  end
  if ctx.is_inline then
    return
  end -- Only works in side-by-side

  local moves = session.stored_diff_result.moves
  if #moves == 0 then
    vim.notify("No moved code blocks in current diff", vim.log.levels.INFO)
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  -- Read current buffers from session (not closure — may have changed via file switch)
  local sess_orig_buf = session.original_bufnr
  local sess_mod_buf = session.modified_bufnr

  -- Find which move the cursor is in
  local current_move = nil
  local is_on_original = current_buf == sess_orig_buf
  for _, move in ipairs(moves) do
    local range = is_on_original and move.original or move.modified
    if cursor_line >= range.start_line and cursor_line < range.end_line then
      current_move = move
      break
    end
  end

  if not current_move then
    vim.notify("Not on a moved code block", vim.log.levels.INFO)
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  local other_win = is_on_original and session.modified_win or session.original_win
  if not vim.api.nvim_win_is_valid(other_win) then
    return
  end

  local my_range = is_on_original and current_move.original or current_move.modified
  local other_range = is_on_original and current_move.modified or current_move.original

  -- Save full view state of both windows
  local current_view = vim.api.nvim_win_call(current_win, function()
    return vim.fn.winsaveview()
  end)
  local other_view = vim.api.nvim_win_call(other_win, function()
    return vim.fn.winsaveview()
  end)
  local saved_scrolloff_other = vim.wo[other_win].scrolloff

  -- Disable native scrollbind while we impose the move alignment.
  vim.wo[current_win].scrollbind = false
  vim.wo[other_win].scrollbind = false
  vim.wo[other_win].scrolloff = 0

  -- Align using the annotation virt_line as anchor:
  -- Both sides have "⇄ moved" above their first moved line.
  -- Use winline() to get the actual visual row (accounts for virtual/filler lines).
  local my_first = my_range.start_line
  local other_first = other_range.start_line

  -- Get actual visual row of the moved block start (accounts for filler virt_lines)
  -- Save and restore cursor so the user's position is not disturbed.
  local my_visual_row = vim.api.nvim_win_call(current_win, function()
    local saved_pos = vim.api.nvim_win_get_cursor(current_win)
    vim.api.nvim_win_set_cursor(current_win, { my_first, 0 })
    local row = vim.fn.winline()
    vim.api.nvim_win_set_cursor(current_win, saved_pos)
    return row
  end)

  -- Set other pane: position other_first at the same visual row
  -- winline() is 1-based from top of window
  vim.api.nvim_win_call(other_win, function()
    -- First scroll to the target line at top of window
    vim.api.nvim_win_set_cursor(other_win, { other_first, 0 })
    vim.cmd("normal! zt")
    -- Now scroll down to match the visual offset (Ctrl-Y scrolls view up, line moves down)
    if my_visual_row > 1 then
      local keys = vim.api.nvim_replace_termcodes((my_visual_row - 1) .. "<C-y>", true, false, true)
      vim.api.nvim_feedkeys(keys, "nx", false)
    end
  end)

  -- Restore function — called when cursor leaves moved block or switches window
  local augroup = vim.api.nvim_create_augroup("codediff_move_align_" .. ctx.tabpage, { clear = true })
  local restored = false

  local function restore()
    if restored then
      return
    end
    restored = true
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    if vim.api.nvim_win_is_valid(other_win) then
      vim.wo[other_win].scrolloff = saved_scrolloff_other
    end
    if not vim.api.nvim_win_is_valid(current_win) or not vim.api.nvim_win_is_valid(other_win) then
      return
    end
    -- Restore views first, then re-establish native scrollbind.
    vim.api.nvim_win_call(other_win, function()
      vim.fn.winrestview(other_view)
    end)
    vim.api.nvim_win_call(current_win, function()
      vim.fn.winrestview(current_view)
    end)

    local session = lifecycle.get_session(ctx.tabpage)
    local orig_win = session and session.original_win or current_win
    local mod_win = session and session.modified_win or other_win
    local orig_bufnr = session and session.original_bufnr or vim.api.nvim_win_get_buf(orig_win)
    local mod_bufnr = session and session.modified_bufnr or vim.api.nvim_win_get_buf(mod_win)
    local diff_result = session and session.stored_diff_result
    local orig_cur = { current_view.lnum, current_view.col }
    local mod_cur = { other_view.lnum, other_view.col }
    if not is_on_original then
      orig_cur, mod_cur = mod_cur, orig_cur
    end
    render.establish_scrollbind(orig_win, mod_win, orig_bufnr, mod_bufnr, diff_result, orig_cur, mod_cur)
  end

  -- Restore when cursor moves out of the moved block
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = current_buf,
    callback = function()
      local new_line = vim.api.nvim_win_get_cursor(0)[1]
      if new_line < my_range.start_line or new_line >= my_range.end_line then
        restore()
      end
    end,
  })

  -- Restore when user switches to another window (WinLeave)
  -- Use vim.schedule to defer restore until after Neovim finishes
  -- the window switch and cursor placement from the click event.
  vim.api.nvim_create_autocmd("WinLeave", {
    group = augroup,
    callback = function()
      vim.schedule(restore)
    end,
  })
end

return M
