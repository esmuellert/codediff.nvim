-- Accessor functions (getters and setters) for diff sessions
local M = {}

-- Lazy require to avoid circular dependency: init → session → accessors → session
local function get_active_diffs()
  return require("codediff.ui.lifecycle.session").get_active_diffs()
end

-- Check if a revision represents a virtual buffer
local function is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

local function clear_gutter_signs(sess)
  local gutter_signs = require("codediff.ui.gutter_signs")
  gutter_signs.clear_buffer(sess.original_bufnr)
  gutter_signs.clear_buffer(sess.modified_bufnr)
end

-- ============================================================================
-- PUBLIC API - GETTERS (return copies/values, safe)
-- ============================================================================

--- Get session
--- @param tabpage number
--- @return table|nil
function M.get_session(tabpage)
  local active_diffs = get_active_diffs()
  return active_diffs[tabpage]
end

--- Get the session's side panel descriptor, or nil for a bare diff
function M.get_panel(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.panel or nil
end

--- Name of the session's side panel, or nil for a bare diff
function M.get_panel_name(tabpage)
  local panel = M.get_panel(tabpage)
  return panel and panel.name or nil
end

--- Legacy "mode" string for the public CodeDiffOpen/CodeDiffClose payload.
--- Documented in the README, so it keeps the pre-panel vocabulary even though
--- nothing inside the plugin reads it any more.
--- @param panel table|nil
--- @return "explorer"|"history"|"standalone"
function M.event_mode(panel)
  return panel and panel.name or "standalone"
end

--- Get current session layout
function M.get_layout(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.layout or nil
end

--- Get git context
function M.get_git_context(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return nil
  end

  return {
    git_root = sess.git_root,
    original_revision = sess.original_revision,
    modified_revision = sess.modified_revision,
  }
end

--- Get buffer IDs
function M.get_buffers(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return nil, nil
  end
  return sess.original_bufnr, sess.modified_bufnr
end

--- Get window IDs
function M.get_windows(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return nil, nil
  end
  return sess.original_win, sess.modified_win
end

--- Get path refs
---@return Path? original, Path? modified
function M.get_paths(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return nil, nil
  end
  return sess.original, sess.modified
end

--- Find tabpage containing a buffer
function M.find_tabpage_by_buffer(bufnr)
  local active_diffs = get_active_diffs()
  for tabpage, sess in pairs(active_diffs) do
    if sess.original_bufnr == bufnr or sess.modified_bufnr == bufnr or sess.result_bufnr == bufnr then
      return tabpage
    end
  end
  return nil
end

--- Check if original buffer is virtual
function M.is_original_virtual(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end
  return is_virtual_revision(sess.original_revision)
end

--- Check if modified buffer is virtual
function M.is_modified_virtual(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end
  return is_virtual_revision(sess.modified_revision)
end

--- Check if suspended
function M.is_suspended(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.suspended or false
end

--- Get explorer reference (for explorer mode)
function M.get_panel_view(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.panel and sess.panel.view
end

--- Get the merge base (stage :1) content for the conflict file.
--- This is the common ancestor — the real "original" — used by smart-combine
--- and discard operations that need merge-base coordinates. Distinct from
--- result_base_lines, which is the auto-merged *seed* content of the Result
--- buffer (and not the merge base).
function M.get_merge_base_lines(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.merge_base_lines
end

--- Get the seed content of the Result buffer (auto-merged result).
--- This is what the Result buffer was initialized to, and what every
--- accept/discard action compares against to decide whether a conflict
--- region is still in its initial unresolved state. NOT the merge base —
--- see get_merge_base_lines for that.
function M.get_result_base_lines(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.result_base_lines
end

--- Get result buffer and window
function M.get_result(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return nil, nil
  end
  return sess.result_bufnr, sess.result_win
end

--- Get conflict blocks for a session
--- @param tabpage number
--- @return table|nil List of conflict blocks
function M.get_conflict_blocks(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.conflict_blocks
end

--- Get all conflict files for a session
function M.get_conflict_files(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return {}
  end
  return sess.conflict_files or {}
end

--- Check if any conflict files have unsaved changes
--- Returns list of unsaved file paths
function M.get_unsaved_conflict_files(tabpage)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess or not sess.conflict_files then
    return {}
  end

  local unsaved = {}
  for file_path, _ in pairs(sess.conflict_files) do
    -- Find buffer for this file
    local bufnr = vim.fn.bufnr(file_path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
      if vim.bo[bufnr].modified then
        table.insert(unsaved, file_path)
      end
    end
  end
  return unsaved
end

-- ============================================================================
-- PUBLIC API - SETTERS (validated mutations)
-- ============================================================================

--- Update suspended state
function M.update_suspended(tabpage, suspended)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.suspended = suspended
  return true
end

--- Update session layout
function M.update_layout(tabpage, layout)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.layout = layout
  if layout == "inline" then
    clear_gutter_signs(sess)
  end
  return true
end

--- Update diff result (cached)
function M.update_diff_result(tabpage, diff_lines)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.stored_diff_result = diff_lines
  return true
end

--- Update changedtick
function M.update_changedtick(tabpage, original_tick, modified_tick)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.changedtick.original = original_tick
  sess.changedtick.modified = modified_tick
  return true
end

--- Update mtime
function M.update_mtime(tabpage, original_mtime, modified_mtime)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.mtime.original = original_mtime
  sess.mtime.modified = modified_mtime
  return true
end

--- Update path refs (for file switching/sync)
---@param original Path
---@param modified Path
function M.update_paths(tabpage, original, modified)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.original = original
  sess.modified = modified
  return true
end

--- Update buffer numbers (for file switching/sync when buffers change)
--- Also updates buffer states (for suspend/resume to work correctly)
function M.update_buffers(tabpage, original_bufnr, modified_bufnr)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  local state = require("codediff.ui.lifecycle.state")
  local gutter_signs = require("codediff.ui.gutter_signs")

  if sess.original_bufnr ~= original_bufnr and sess.original_bufnr ~= modified_bufnr then
    gutter_signs.clear_buffer(sess.original_bufnr)
  end
  if sess.modified_bufnr ~= original_bufnr and sess.modified_bufnr ~= modified_bufnr then
    gutter_signs.clear_buffer(sess.modified_bufnr)
  end

  -- Hand mappings back to any buffer that is leaving the session. Without this
  -- the previous file keeps codediff's keys until the tab is closed.
  if sess.keymaps then
    local keep = {}
    if original_bufnr then
      keep[original_bufnr] = true
    end
    if modified_bufnr then
      keep[modified_bufnr] = true
    end
    local panel_view = sess.panel and sess.panel.view
    if panel_view and panel_view.bufnr then
      keep[panel_view.bufnr] = true
    end
    if sess.result_bufnr then
      keep[sess.result_bufnr] = true
    end
    sess.keymaps:detach_buffers_except(keep)
  end

  sess.original_bufnr = original_bufnr
  sess.modified_bufnr = modified_bufnr

  -- Save buffer states for new buffers (critical for suspend/resume!)
  sess.original_state = state.save_buffer_state(original_bufnr)
  sess.modified_state = state.save_buffer_state(modified_bufnr)

  return true
end

--- Update git root (for file switching when changing repos)
function M.update_git_root(tabpage, git_root)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.git_root = git_root
  return true
end

--- Update revisions (for file switching/sync)
function M.update_revisions(tabpage, original_revision, modified_revision)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.original_revision = original_revision
  sess.modified_revision = modified_revision
  return true
end

--- Set explorer reference (for explorer mode)
function M.set_panel_view(tabpage, view)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.panel = sess.panel or {}
  sess.panel.view = view
  if sess.reapply_keymaps then
    sess.reapply_keymaps()
  end
  return true
end

--- Set whether this session is a 3-way merge view.
--- Fixed for a given file, but view.update can retarget a session between a
--- conflicted file and an ordinary one, so it has to follow.
--- @param tabpage number
--- @param merge boolean|nil
--- @return boolean success
function M.update_merge(tabpage, merge)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end
  sess.merge = merge or nil
  return true
end

--- Set result buffer and window (for conflict mode)
function M.set_result(tabpage, result_bufnr, result_win)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  -- Leaving conflict mode: retire the conflict mappings so do/dp and the
  -- ordinary view mappings can be claimed again on the next setup pass.
  if result_bufnr == nil and sess.result_bufnr ~= nil then
    if sess.keymaps then
      sess.keymaps:release_scope("conflict")
    end
    require("codediff.ui.conflict").teardown_gutter(tabpage)
    require("codediff.ui.auto_refresh").disable_result(sess.result_bufnr)
    sess.conflict_blocks = nil
    sess.result_base_lines = nil
    sess.merge_base_lines = nil
  end

  sess.result_bufnr = result_bufnr
  sess.result_win = result_win

  -- Mark result window with restore flag
  if result_win and vim.api.nvim_win_is_valid(result_win) then
    vim.w[result_win].codediff_restore = 1
  end
  if result_win then
    clear_gutter_signs(sess)
  end

  return true
end

--- Store the seed content for the Result buffer (auto-merged result).
--- See get_result_base_lines for semantics.
function M.set_result_base_lines(tabpage, result_base_lines)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end
  sess.result_base_lines = result_base_lines
  return true
end

--- Store the merge base (stage :1) content for the conflict file.
--- See get_merge_base_lines for semantics; this is kept separate from
--- result_base_lines so smart-combine can still walk merge-base coordinates
--- after the Result buffer has been auto-merged.
function M.set_merge_base_lines(tabpage, merge_base_lines)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end
  sess.merge_base_lines = merge_base_lines
  return true
end

--- Store conflict blocks (mapping alignments) for a session
--- @param tabpage number
--- @param blocks table List of conflict blocks from compute_mapping_alignments
function M.set_conflict_blocks(tabpage, blocks)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end
  sess.conflict_blocks = blocks
  return true
end

--- Track a file opened in conflict mode (for unsaved warning)
function M.track_conflict_file(tabpage, file_path)
  local active_diffs = get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.conflict_files = sess.conflict_files or {}
  sess.conflict_files[file_path] = true
  return true
end

--- Prompt user about unsaved conflict files before closing
--- Returns true if user confirms close, false if cancelled
function M.confirm_close_with_unsaved(tabpage)
  local unsaved = M.get_unsaved_conflict_files(tabpage)
  if #unsaved == 0 then
    return true -- No unsaved files, proceed
  end

  -- Build message
  local msg = "The following merge result files have unsaved changes:\n\n"
  for _, path in ipairs(unsaved) do
    -- Show just filename for readability
    local filename = vim.fn.fnamemodify(path, ":t")
    msg = msg .. "  • " .. filename .. "\n"
  end
  msg = msg .. "\nDiscard changes and close?"

  -- Show confirmation dialog
  local choice = vim.fn.confirm(msg, "&Discard\n&Cancel", 2, "Warning")

  if choice == 1 then
    -- Discard: reload buffers from disk to restore original content (with conflict markers)
    for _, path in ipairs(unsaved) do
      local bufnr = vim.fn.bufnr(path)
      if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
        -- Reload from disk to restore original file content
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("edit!")
        end)
      end
    end
    return true
  else
    -- Cancel
    return false
  end
end

return M
