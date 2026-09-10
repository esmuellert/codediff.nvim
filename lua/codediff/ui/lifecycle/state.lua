-- State management for diff views
-- Handles save/restore, suspend/resume, and buffer state
local M = {}

local highlights = require("codediff.ui.highlights")

-- Save buffer state before modifications
local function save_buffer_state(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local state = {}

  -- Save inlay hint state (Neovim 0.10+)
  if vim.lsp.inlay_hint then
    state.inlay_hints_enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr })
  end

  return state
end

M.save_buffer_state = save_buffer_state

-- Restore buffer state after cleanup
local function restore_buffer_state(bufnr, state)
  if not vim.api.nvim_buf_is_valid(bufnr) or not state then
    return
  end

  -- Restore inlay hint state
  if vim.lsp.inlay_hint and state.inlay_hints_enabled ~= nil then
    vim.lsp.inlay_hint.enable(state.inlay_hints_enabled, { bufnr = bufnr })
  end
end

M.restore_buffer_state = restore_buffer_state

-- Clear highlights and extmarks from a buffer
-- @param bufnr number: Buffer number to clean
local function clear_buffer_highlights(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Clear highlight, filler, conflict sign, and inline namespaces
  vim.api.nvim_buf_clear_namespace(bufnr, highlights.ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, highlights.ns_filler, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, highlights.ns_conflict, 0, -1)
  local ns_inline = vim.api.nvim_create_namespace("codediff-inline")
  vim.api.nvim_buf_clear_namespace(bufnr, ns_inline, 0, -1)
  require("codediff.ui.gutter_signs").clear_buffer(bufnr)
end

M.clear_buffer_highlights = clear_buffer_highlights

-- Get file modification time (mtime)
local function get_file_mtime(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local bufname = vim.api.nvim_buf_get_name(bufnr)

  -- Virtual buffers don't have mtime
  if bufname:match("^codediff://") or bufname == "" then
    return nil
  end

  -- Get file stat
  local stat = vim.loop.fs_stat(bufname)
  return stat and stat.mtime.sec or nil
end

M.get_file_mtime = get_file_mtime

-- Check if a revision represents a virtual buffer
local function is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

-- Suspend diff view (when leaving tab)
-- @param tabpage number: Tab page ID
local function suspend_diff(tabpage)
  local session = require("codediff.ui.lifecycle.session")
  local active_diffs = session.get_active_diffs()
  local diff = active_diffs[tabpage]
  if not diff or diff.suspended then
    return
  end

  -- Disable auto-refresh (stop watching buffer changes)
  local auto_refresh = require("codediff.ui.auto_refresh")
  auto_refresh.disable(diff.original_bufnr)
  auto_refresh.disable(diff.modified_bufnr)
  if diff.result_bufnr then
    auto_refresh.disable_result(diff.result_bufnr)
  end

  -- Clear highlights from both buffers
  clear_buffer_highlights(diff.original_bufnr)
  clear_buffer_highlights(diff.modified_bufnr)
  if diff.result_bufnr then
    clear_buffer_highlights(diff.result_bufnr)
  end

  -- Mark as suspended
  diff.suspended = true
end

M.suspend_diff = suspend_diff

-- Resume diff view (when entering tab)
-- @param tabpage number: Tab page ID
local function resume_diff(tabpage)
  local session = require("codediff.ui.lifecycle.session")
  local active_diffs = session.get_active_diffs()
  local diff = active_diffs[tabpage]
  if not diff or not diff.suspended then
    return
  end

  -- Check if buffers still exist. Dropping the session here would otherwise
  -- orphan its registry, leaving codediff's mappings installed on whichever
  -- pane survived and its saved user mappings unreachable.
  if not vim.api.nvim_buf_is_valid(diff.original_bufnr) or not vim.api.nvim_buf_is_valid(diff.modified_bufnr) then
    require("codediff.ui.conflict").teardown_gutter(tabpage)
    if diff.keymaps then
      diff.keymaps:dispose()
      diff.keymaps = nil
    end
    active_diffs[tabpage] = nil
    return
  end

  if diff.single_side then
    local core = require("codediff.ui.core")
    local bufnr = diff[diff.single_side .. "_bufnr"]
    core.render_whole_file(bufnr, diff.single_side)
    diff.suspended = false
    return
  end

  -- Check if buffer or file changed while suspended
  local original_tick_changed = vim.api.nvim_buf_get_changedtick(diff.original_bufnr) ~= diff.changedtick.original
  local modified_tick_changed = vim.api.nvim_buf_get_changedtick(diff.modified_bufnr) ~= diff.changedtick.modified

  local original_mtime_changed = false
  local modified_mtime_changed = false

  if diff.mtime.original then
    local current_mtime = get_file_mtime(diff.original_bufnr)
    original_mtime_changed = current_mtime ~= diff.mtime.original
  end

  if diff.mtime.modified then
    local current_mtime = get_file_mtime(diff.modified_bufnr)
    modified_mtime_changed = current_mtime ~= diff.mtime.modified
  end

  local need_recompute = original_tick_changed or modified_tick_changed or original_mtime_changed or modified_mtime_changed

  -- Always get fresh buffer content for rendering
  local original_lines = vim.api.nvim_buf_get_lines(diff.original_bufnr, 0, -1, false)
  local modified_lines = vim.api.nvim_buf_get_lines(diff.modified_bufnr, 0, -1, false)

  local lines_diff
  local diff_was_recomputed = false

  if need_recompute or not diff.stored_diff_result then
    -- Buffer or file changed, recompute diff
    local diff_module = require("codediff.core.diff")
    local config = require("codediff.config")
    lines_diff = diff_module.compute_diff(original_lines, modified_lines, {
      max_computation_time_ms = config.options.diff.max_computation_time_ms,
      ignore_trim_whitespace = config.options.diff.ignore_trim_whitespace,
      compute_moves = config.options.diff.compute_moves,
    })
    diff_was_recomputed = true

    if lines_diff then
      -- Store new diff result
      diff.stored_diff_result = lines_diff

      -- Update changedtick and mtime
      diff.changedtick.original = vim.api.nvim_buf_get_changedtick(diff.original_bufnr)
      diff.changedtick.modified = vim.api.nvim_buf_get_changedtick(diff.modified_bufnr)
      diff.mtime.original = get_file_mtime(diff.original_bufnr)
      diff.mtime.modified = get_file_mtime(diff.modified_bufnr)
    end
  else
    -- Nothing changed, reuse stored diff result
    lines_diff = diff.stored_diff_result
  end

  -- Render with fresh content and (possibly reused) diff result
  if lines_diff then
    if diff.result_bufnr and diff.merge_base_lines and diff.conflict_blocks then
      -- Conflict inputs are two diffs against BASE, not a diff against each
      -- other. Restore that same geometry without resetting Result or its
      -- tracking extmarks, so accepted edits and gutter colors survive tabs.
      local diff_module = require("codediff.core.diff")
      local options = require("codediff.config").options.diff
      local diff_options = {
        max_computation_time_ms = options.max_computation_time_ms,
        ignore_trim_whitespace = options.ignore_trim_whitespace,
        compute_moves = options.compute_moves,
      }
      local original_diff = diff_module.compute_diff(diff.merge_base_lines, original_lines, diff_options)
      local modified_diff = diff_module.compute_diff(diff.merge_base_lines, modified_lines, diff_options)
      if original_diff and modified_diff then
        require("codediff.ui.core").render_merge_view(diff.original_bufnr, diff.modified_bufnr, original_diff, modified_diff, diff.merge_base_lines, original_lines, modified_lines)
        diff.stored_diff_result = modified_diff
        local conflict = require("codediff.ui.conflict")
        conflict.attach_gutter(diff.original_win, diff.modified_win)
        conflict.refresh(diff)
      end
    elseif diff.layout == "inline" then
      local inline_mod = require("codediff.ui.inline")
      inline_mod.render_inline_diff(diff.modified_bufnr, lines_diff, original_lines, modified_lines)
    else
      local core = require("codediff.ui.core")
      core.render_diff(diff.original_bufnr, diff.modified_bufnr, original_lines, modified_lines, lines_diff)
    end

    -- Re-sync scrollbind ONLY if diff was recomputed and not inline mode.
    if
      diff_was_recomputed
      and diff.layout ~= "inline"
      and diff.original_win
      and diff.modified_win
      and vim.api.nvim_win_is_valid(diff.original_win)
      and vim.api.nvim_win_is_valid(diff.modified_win)
    then
      local current_win = vim.api.nvim_get_current_win()
      local result_win = diff.result_win and vim.api.nvim_win_is_valid(diff.result_win) and diff.result_win or nil

      if current_win == diff.original_win or current_win == diff.modified_win or current_win == result_win then
        local saved_cursor = vim.api.nvim_win_get_cursor(current_win)

        vim.api.nvim_win_set_cursor(diff.original_win, { 1, 0 })
        vim.api.nvim_win_set_cursor(diff.modified_win, { 1, 0 })
        if result_win then
          vim.api.nvim_win_set_cursor(result_win, { 1, 0 })
        end

        vim.wo[diff.original_win].scrollbind = false
        vim.wo[diff.modified_win].scrollbind = false
        if result_win then
          vim.wo[result_win].scrollbind = false
        end
        vim.wo[diff.original_win].scrollbind = true
        vim.wo[diff.modified_win].scrollbind = true
        if result_win then
          vim.wo[result_win].scrollbind = true
        end

        vim.wo[diff.original_win].wrap = false
        vim.wo[diff.modified_win].wrap = false
        if result_win then
          vim.wo[result_win].wrap = false
        end

        pcall(vim.api.nvim_win_set_cursor, diff.original_win, saved_cursor)
        pcall(vim.api.nvim_win_set_cursor, diff.modified_win, saved_cursor)
        if result_win then
          pcall(vim.api.nvim_win_set_cursor, result_win, saved_cursor)
        end
      end
    end
  end

  -- Re-enable auto-refresh for real buffers only
  local auto_refresh = require("codediff.ui.auto_refresh")

  -- Check if buffers are real files (not virtual) using revision
  local original_is_real = not is_virtual_revision(diff.original_revision)
  local modified_is_real = not is_virtual_revision(diff.modified_revision)

  if original_is_real then
    auto_refresh.enable(diff.original_bufnr)
  end

  if modified_is_real then
    auto_refresh.enable(diff.modified_bufnr)
  end

  -- Re-enable auto-refresh for result buffer if in conflict mode
  if diff.result_bufnr and vim.api.nvim_buf_is_valid(diff.result_bufnr) and diff.result_base_lines then
    auto_refresh.enable_for_result(diff.result_bufnr)
  end

  -- Mark as active
  diff.suspended = false
end

M.resume_diff = resume_diff

return M
