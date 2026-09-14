-- Diff computation and rendering for inline views.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local render = require("codediff.ui.view.render")
local cursor_util = require("codediff.ui.view.cursor")

function M.compute_and_render_inline(modified_buf, original_buf, original_lines, modified_lines, original_is_virtual, modified_is_virtual, modified_win, auto_scroll_to_first_hunk)
  local lines_diff = render.render_diff(original_buf, modified_buf, original_lines, modified_lines, "inline")
  if not lines_diff then
    return
  end

  if modified_win and vim.api.nvim_win_is_valid(modified_win) then
    vim.wo[modified_win].wrap = false
    if auto_scroll_to_first_hunk and lines_diff.changes and #lines_diff.changes > 0 then
      -- Honor session.pending_cursor_landing (cycle-hunks-across-files
      -- backward direction sets it to "last"; see ui/view/navigation.lua).
      -- Look up the session via the window's tabpage because this code can
      -- run from a scheduled callback on a different tab.
      local lifecycle = require("codediff.ui.lifecycle")
      local tabpage = vim.api.nvim_win_get_tabpage(modified_win)
      local session = tabpage and lifecycle.get_session(tabpage) or nil
      local landing = session and session.pending_cursor_landing
      if session then
        session.pending_cursor_landing = nil
      end

      local target_line = landing == "last" and lines_diff.changes[#lines_diff.changes].modified.start_line or lines_diff.changes[1].modified.start_line
      target_line = cursor_util.clamp_window_line(modified_win, target_line)
      pcall(vim.api.nvim_win_set_cursor, modified_win, { target_line, 0 })
      vim.api.nvim_set_current_win(modified_win)
      vim.cmd("normal! zz")
    end
  end

  return lines_diff
end

function M.rerender(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or session.layout ~= "inline" then
    return
  end

  local original_bufnr = session.original_bufnr
  local modified_bufnr = session.modified_bufnr

  if not vim.api.nvim_buf_is_valid(original_bufnr) or not vim.api.nvim_buf_is_valid(modified_bufnr) then
    return
  end

  local original_lines = vim.api.nvim_buf_get_lines(original_bufnr, 0, -1, false)
  local modified_lines = vim.api.nvim_buf_get_lines(modified_bufnr, 0, -1, false)

  local lines_diff = render.render_diff(original_bufnr, modified_bufnr, original_lines, modified_lines, "inline")
  if lines_diff then
    lifecycle.update_diff_result(tabpage, lines_diff)
  end
end

return M
