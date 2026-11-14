-- Hover preview of a conflict hunk against the merge base
-- The side's lines are real text; the base lines it replaced are the inline renderer's virtual lines.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")
local tracking = require("codediff.ui.conflict.tracking")
local inline = require("codediff.ui.inline")
local virtual_file = require("codediff.core.virtual_file")

--- Toggle a float showing the conflict under the cursor against the merge base
--- @param tabpage number
--- @return boolean shown
function M.toggle(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  if session._hover_win and vim.api.nvim_win_is_valid(session._hover_win) then
    vim.api.nvim_win_close(session._hover_win, true)
    session._hover_win = nil
    return false
  end

  local source = vim.api.nvim_get_current_buf()
  local side = (source == session.original_bufnr and "left") or
      (source == session.modified_bufnr and "right") or nil
  local block = side and session.conflict_blocks and
      tracking.find_conflict_at_cursor(session, vim.api.nvim_win_get_cursor(0)[1], side, true)
  if not block then
    vim.notify("[codediff] No conflict at cursor position", vim.log.levels.INFO)
    return false
  end

  local range = side == "left" and block.output1_range or block.output2_range
  local lines = tracking.get_lines_for_range(source, range.start_line, range.end_line)
  local base_lines = session.merge_base_lines or {}
  local base = {}
  for i = block.base_range.start_line, block.base_range.end_line - 1 do
    table.insert(base, base_lines[i] or "")
  end

  local diff
  if #base == 0 or #lines == 0 then
    -- The diff engine reports no changes when either side is empty
    diff = { changes = { { original = { start_line = 1, end_line = #base + 1 }, modified = { start_line = 1, end_line = #lines + 1 } } } }
  else
    diff = require("codediff.core.diff").compute_diff(base, lines,
      require("codediff.ui.view.render").diff_options())
  end

  -- A deletion past the last line is drawn above that line; a spare row keeps it below
  local text = vim.list_extend({}, lines)
  local last = diff.changes[#diff.changes]
  if last and #lines > 0 and last.modified.start_line > #lines then
    table.insert(text, "")
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  virtual_file.set_content(buf, text, vim.api.nvim_buf_get_name(session.result_bufnr))
  inline.render_inline_diff(buf, diff, base, lines,
    { filetype = vim.bo[session.result_bufnr].filetype })

  -- Virtual lines above row 0 only show when topfill matches their count exactly
  local fill, topfill = 0, 0
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })) do
    local count = #(mark[4].virt_lines or {})
    fill = fill + count
    if mark[2] == 0 then
      topfill = topfill + count
    end
  end

  local ours = (side == "left") == (config.options.diff.conflict_ours_position == "left")
  local title = ours and " Ours (Current) vs Base " or " Theirs (Incoming) vs Base "
  local width = vim.fn.strdisplaywidth(title)
  for _, line in ipairs(vim.list_extend(vim.list_extend({}, base), lines)) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.max(1, math.min(width, vim.o.columns - 4)),
    height = math.max(1, math.min(vim.api.nvim_buf_line_count(buf) + fill, vim.o.lines - 4)),
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    focusable = false,
  })
  -- Floats inherit the pane's window options; scrollbind would drag the float along with the panes
  vim.wo[win].scrollbind = false
  vim.wo[win].foldenable = false
  vim.wo[win].wrap = false
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topfill = topfill })
  end)
  session._hover_win = win

  vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
    buffer = source,
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  })
  return true
end

return M
