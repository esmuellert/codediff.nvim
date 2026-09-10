-- Diff computation and rendering for diff view
local M = {}

local core = require("codediff.ui.core")
local config = require("codediff.config")
local diff_module = require("codediff.core.diff")
local cursor_util = require("codediff.ui.view.cursor")

--- Establish native scrollbind between two windows using the anchor technique.
--- Anchors at the first unchanged line for insertions/deletions at the start of
--- a file, so `syncbind` establishes the correct baseline before the view is
--- positioned on the requested hunk.
--- @param orig_win number
--- @param mod_win number
--- @param orig_buf number
--- @param mod_buf number
--- @param lines_diff table: diff result with .changes
--- @param orig_cursor table|nil: {line, col} to restore on original side
--- @param mod_cursor table|nil: {line, col} to restore on modified side
function M.establish_scrollbind(orig_win, mod_win, orig_buf, mod_buf, lines_diff, orig_cursor, mod_cursor)
  local function set_cursor(win, cursor)
    if cursor then
      pcall(vim.api.nvim_win_set_cursor, win, cursor_util.clamp_cursor(win, cursor))
    end
  end

  -- When the first change is a pure insertion/deletion at line 1, filler
  -- virt_lines sit above line 1 on one side. Start at the first corresponding
  -- unchanged line so syncbind establishes the correct baseline.
  if lines_diff and lines_diff.changes and #lines_diff.changes > 0 then
    local first = lines_diff.changes[1]
    local orig_empty = first.original.start_line >= first.original.end_line
    local mod_empty = first.modified.start_line >= first.modified.end_line
    if (first.original.start_line == 1 or first.modified.start_line == 1) and (orig_empty or mod_empty) then
      local anchor_orig = math.max(first.original.end_line, 1)
      local anchor_mod = math.max(first.modified.end_line, 1)
      anchor_orig = math.min(anchor_orig, vim.api.nvim_buf_line_count(orig_buf))
      anchor_mod = math.min(anchor_mod, vim.api.nvim_buf_line_count(mod_buf))
      set_cursor(orig_win, { anchor_orig, 0 })
      set_cursor(mod_win, { anchor_mod, 0 })
      vim.wo[orig_win].scrollbind = true
      vim.wo[mod_win].scrollbind = true
      vim.cmd("syncbind")
      return
    end
  end

  -- Normal path: establish the native baseline at line 1, then restore the
  -- requested per-pane cursor positions.
  set_cursor(orig_win, { 1, 0 })
  set_cursor(mod_win, { 1, 0 })
  vim.wo[orig_win].scrollbind = true
  vim.wo[mod_win].scrollbind = true
  set_cursor(orig_win, orig_cursor)
  set_cursor(mod_win, mod_cursor)
end

-- Common logic: Compute diff and render highlights
-- @param auto_scroll_to_first_hunk boolean: Whether to auto-scroll to first change (default true)
-- @param line_range table?: Optional {start_line, end_line} to scroll to instead of first hunk
function M.compute_and_render(
  original_buf,
  modified_buf,
  original_lines,
  modified_lines,
  original_is_virtual,
  modified_is_virtual,
  original_win,
  modified_win,
  auto_scroll_to_first_hunk,
  line_range
)
  -- Compute diff
  local diff_options = {
    max_computation_time_ms = config.options.diff.max_computation_time_ms,
    ignore_trim_whitespace = config.options.diff.ignore_trim_whitespace,
    compute_moves = config.options.diff.compute_moves,
  }
  local lines_diff = diff_module.compute_diff(original_lines, modified_lines, diff_options)
  if not lines_diff then
    vim.notify("Failed to compute diff", vim.log.levels.ERROR)
    return nil
  end

  -- Render diff highlights
  core.render_diff(original_buf, modified_buf, original_lines, modified_lines, lines_diff)

  -- Setup scroll synchronization (only if windows provided)
  if original_win and modified_win and vim.api.nvim_win_is_valid(original_win) and vim.api.nvim_win_is_valid(modified_win) then
    -- Save cursor position if we need to preserve it (on update)
    local saved_cursor = nil
    if not auto_scroll_to_first_hunk then
      saved_cursor = vim.api.nvim_win_get_cursor(modified_win)
    end

    -- Step 1: Disable native scrollbind while repositioning cursors and disable wrap
    vim.wo[original_win].scrollbind = false
    vim.wo[modified_win].scrollbind = false
    vim.wo[original_win].wrap = false
    vim.wo[modified_win].wrap = false

    -- Step 2: Determine target cursor positions.
    -- The two panes show different content, so original/modified line
    -- numbers for the same hunk diverge whenever there are insertions or
    -- deletions before it. Use per-pane coordinates (matches the
    -- ui/view/navigation.lua next_hunk/prev_hunk convention).
    local orig_cursor, mod_cursor
    if auto_scroll_to_first_hunk and #lines_diff.changes > 0 then
      -- Honor session.pending_cursor_landing (set by the cycle-hunks-across-
      -- files navigation path; see ui/view/navigation.lua). It's a one-shot
      -- intent — read and clear here so the next render doesn't reapply it.
      -- Look up the session by the modified window's tabpage rather than
      -- find_tabpage_by_buffer (the session's bufnrs are updated AFTER
      -- this render in the file-switch path) or current tabpage (this code
      -- can run from a scheduled callback on a different tab).
      local lifecycle = require("codediff.ui.lifecycle")
      local tabpage = (modified_win and vim.api.nvim_win_is_valid(modified_win)) and vim.api.nvim_win_get_tabpage(modified_win) or nil
      local session = tabpage and lifecycle.get_session(tabpage) or nil
      local landing = session and session.pending_cursor_landing
      if session then
        session.pending_cursor_landing = nil
      end

      if line_range then
        -- Range mode: find the first hunk overlapping the line range, then
        -- use original-side coords for that hunk on both panes (line_range
        -- itself is original-side input from history mode).
        local target_line
        local range_start, range_end = line_range[1], line_range[2]
        for _, change in ipairs(lines_diff.changes) do
          local hunk_start = change.original.start_line
          local hunk_end = change.original.end_line
          if hunk_end >= range_start and hunk_start <= range_end then
            target_line = hunk_start
            break
          end
        end
        if not target_line then
          target_line = range_start
        end
        orig_cursor = { target_line, 0 }
        mod_cursor = { target_line, 0 }
      else
        local hunk = landing == "last" and lines_diff.changes[#lines_diff.changes] or lines_diff.changes[1]
        orig_cursor = { hunk.original.start_line, 0 }
        mod_cursor = { hunk.modified.start_line, 0 }
      end
    elseif saved_cursor then
      orig_cursor = { saved_cursor[1], 0 }
      mod_cursor = saved_cursor
    else
      orig_cursor = { 1, 0 }
      mod_cursor = { 1, 0 }
    end

    -- Step 3: Position cursors and establish native scrollbind
    M.establish_scrollbind(original_win, modified_win, original_buf, modified_buf, lines_diff, orig_cursor, mod_cursor)

    -- Step 4: Center view on first hunk for initial open
    if auto_scroll_to_first_hunk and #lines_diff.changes > 0 then
      if vim.api.nvim_win_is_valid(modified_win) then
        vim.api.nvim_set_current_win(modified_win)
        vim.cmd("normal! zz")
      end
    end
  end

  return lines_diff
end

-- Common logic: Setup auto-refresh for all diff buffers (real and virtual)
function M.setup_auto_refresh(original_buf, modified_buf, original_is_virtual, modified_is_virtual)
  local auto_refresh = require("codediff.ui.auto_refresh")
  auto_refresh.enable(original_buf)
  auto_refresh.enable(modified_buf)
end

return M
