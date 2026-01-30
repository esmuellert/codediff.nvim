-- Accessor functions (getters and setters) for diff sessions
local M = {}
local config = require("codediff.config")

-- Will be injected by init.lua
local session = nil
M._set_session_module = function(s)
  session = s
end

-- Check if a revision represents a virtual buffer
local function is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

-- ============================================================================
-- PUBLIC API - GETTERS (return copies/values, safe)
-- ============================================================================

--- Get session
--- @param tabpage number
--- @return table|nil
function M.get_session(tabpage)
  local active_diffs = session.get_active_diffs()
  return active_diffs[tabpage]
end

--- Get mode
function M.get_mode(tabpage)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.mode or nil
end

--- Get git context
function M.get_git_context(tabpage)
  local active_diffs = session.get_active_diffs()
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
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return nil, nil
  end
  return sess.original_bufnr, sess.modified_bufnr
end

--- Get window IDs
function M.get_windows(tabpage)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return nil, nil
  end
  return sess.original_win, sess.modified_win
end

--- Get paths
function M.get_paths(tabpage)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return nil, nil
  end
  return sess.original_path, sess.modified_path
end

--- Find tabpage containing a buffer
function M.find_tabpage_by_buffer(bufnr)
  local active_diffs = session.get_active_diffs()
  for tabpage, sess in pairs(active_diffs) do
    if sess.original_bufnr == bufnr or sess.modified_bufnr == bufnr or sess.result_bufnr == bufnr then
      return tabpage
    end
  end
  return nil
end

--- Check if original buffer is virtual
function M.is_original_virtual(tabpage)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end
  return is_virtual_revision(sess.original_revision)
end

--- Check if modified buffer is virtual
function M.is_modified_virtual(tabpage)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end
  return is_virtual_revision(sess.modified_revision)
end

--- Check if suspended
function M.is_suspended(tabpage)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.suspended or false
end

--- Get explorer reference (for explorer mode)
function M.get_explorer(tabpage)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.explorer
end

--- Get BASE lines for result buffer diff
function M.get_result_base_lines(tabpage)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.result_base_lines
end

--- Get result buffer and window
function M.get_result(tabpage)
  local active_diffs = session.get_active_diffs()
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
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  return sess and sess.conflict_blocks
end

--- Get all conflict files for a session
function M.get_conflict_files(tabpage)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return {}
  end
  return sess.conflict_files or {}
end

--- Check if any conflict files have unsaved changes
--- Returns list of unsaved file paths
function M.get_unsaved_conflict_files(tabpage)
  local active_diffs = session.get_active_diffs()
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
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.suspended = suspended
  return true
end

--- Update diff result (cached)
function M.update_diff_result(tabpage, diff_lines)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.stored_diff_result = diff_lines
  return true
end

--- Update changedtick
function M.update_changedtick(tabpage, original_tick, modified_tick)
  local active_diffs = session.get_active_diffs()
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
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.mtime.original = original_mtime
  sess.mtime.modified = modified_mtime
  return true
end

--- Update paths (for file switching/sync)
function M.update_paths(tabpage, original_path, modified_path)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.original_path = original_path
  sess.modified_path = modified_path
  return true
end

--- Update buffer numbers (for file switching/sync when buffers change)
--- Also updates buffer states (for suspend/resume to work correctly)
function M.update_buffers(tabpage, original_bufnr, modified_bufnr)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  local state = require("codediff.ui.lifecycle.state")

  sess.original_bufnr = original_bufnr
  sess.modified_bufnr = modified_bufnr

  -- Save buffer states for new buffers (critical for suspend/resume!)
  sess.original_state = state.save_buffer_state(original_bufnr)
  sess.modified_state = state.save_buffer_state(modified_bufnr)

  return true
end

--- Update git root (for file switching when changing repos)
function M.update_git_root(tabpage, git_root)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.git_root = git_root
  return true
end

--- Update revisions (for file switching/sync)
function M.update_revisions(tabpage, original_revision, modified_revision)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.original_revision = original_revision
  sess.modified_revision = modified_revision
  return true
end

--- Set explorer reference (for explorer mode)
function M.set_explorer(tabpage, explorer)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.explorer = explorer
  return true
end

--- Set result buffer and window (for conflict mode)
function M.set_result(tabpage, result_bufnr, result_win)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  sess.result_bufnr = result_bufnr
  sess.result_win = result_win

  -- Mark result window with restore flag
  if result_win and vim.api.nvim_win_is_valid(result_win) then
    vim.w[result_win].codediff_restore = 1
  end

  return true
end

--- Store BASE lines for result buffer diff (for conflict mode)
function M.set_result_base_lines(tabpage, base_lines)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end
  sess.result_base_lines = base_lines
  return true
end

--- Store conflict blocks (mapping alignments) for a session
--- @param tabpage number
--- @param blocks table List of conflict blocks from compute_mapping_alignments
function M.set_conflict_blocks(tabpage, blocks)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end
  sess.conflict_blocks = blocks
  return true
end

--- Track a file opened in conflict mode (for unsaved warning)
function M.track_conflict_file(tabpage, file_path)
  local active_diffs = session.get_active_diffs()
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

--- Find and save an existing buffer-local keymap before overwriting
--- @param bufnr number Buffer number
--- @param mode string Keymap mode
--- @param lhs string Left-hand side of the keymap
--- @return table|nil The saved keymap data, or nil if no existing keymap
local function save_existing_keymap(bufnr, mode, lhs)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local keymaps = vim.api.nvim_buf_get_keymap(bufnr, mode)
  for _, map in ipairs(keymaps) do
    if map.lhs == lhs then
      return {
        lhs = map.lhs,
        rhs = map.rhs,
        callback = map.callback,
        expr = map.expr == 1,
        noremap = map.noremap == 1,
        nowait = map.nowait == 1,
        silent = map.silent == 1,
        script = map.script == 1,
        desc = map.desc,
      }
    end
  end
  return nil
end

--- Set a keymap on all buffers in the diff tab (both diff buffers + explorer + result)
--- This is the unified API for setting tab-wide keymaps
--- @param tabpage number Tab page ID
--- @param mode string Keymap mode ('n', 'v', etc.)
--- @param lhs string Left-hand side of the keymap
--- @param rhs function|string Right-hand side (callback or command)
--- @param opts? table Optional keymap options (will be merged with buffer-local defaults)
--- @return boolean success True if keymaps were set
function M.set_tab_keymap(tabpage, mode, lhs, rhs, opts)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return false
  end

  -- Initialize saved keymaps storage if needed
  sess.saved_keymaps = sess.saved_keymaps or {}

  opts = opts or {}
  local base_opts = { noremap = true, silent = true, nowait = true }

  -- Helper to save existing keymap before setting new one
  local function set_with_save(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    -- Save existing keymap (only if not already saved for this buffer/lhs)
    local key = bufnr .. ":" .. mode .. ":" .. lhs
    if sess.saved_keymaps[key] == nil then
      local existing = save_existing_keymap(bufnr, mode, lhs)
      -- Store even if nil (marks that we've checked this keymap)
      sess.saved_keymaps[key] = existing or false
    end
    vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", base_opts, opts, { buffer = bufnr }))
  end

  set_with_save(sess.original_bufnr)
  set_with_save(sess.modified_bufnr)

  local explorer = sess.explorer
  if explorer and explorer.bufnr then
    set_with_save(explorer.bufnr)
  end

  if sess.result_bufnr then
    set_with_save(sess.result_bufnr)
  end

  return true
end

--- Remove codediff keymaps from a session's buffers and restore original keymaps
function M.clear_tab_keymaps(tabpage)
  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    return
  end

  -- Guard: If already cleared, don't run again (prevents double-cleanup from deleting restored keymaps)
  if not sess.saved_keymaps then
    return
  end

  local saved_keymaps = sess.saved_keymaps

  -- Helper to restore a single keymap
  local function restore_keymap(bufnr, mode, lhs)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local key = bufnr .. ":" .. mode .. ":" .. lhs
    local saved = saved_keymaps[key]

    -- First, delete the codediff keymap
    pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })

    -- Then restore the original keymap if one existed
    if saved and saved ~= false then
      local restore_opts = {
        buffer = bufnr,
        expr = saved.expr,
        noremap = saved.noremap,
        nowait = saved.nowait,
        silent = saved.silent,
        desc = saved.desc,
      }
      local rhs = saved.callback or saved.rhs or ""
      pcall(vim.keymap.set, mode, lhs, rhs, restore_opts)
    end
  end

  -- Helper to restore keymaps for a buffer from a keymap config table
  local function restore_buf_keymaps(bufnr, keys)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    for _, lhs in pairs(keys) do
      if lhs then
        restore_keymap(bufnr, "n", lhs)
      end
    end
  end

  restore_buf_keymaps(sess.original_bufnr, config.options.keymaps.view)
  restore_buf_keymaps(sess.modified_bufnr, config.options.keymaps.view)

  if sess.explorer and sess.explorer.bufnr then
    restore_buf_keymaps(sess.explorer.bufnr, config.options.keymaps.view)
    restore_buf_keymaps(sess.explorer.bufnr, config.options.keymaps.explorer or {})
  end

  if sess.result_bufnr then
    restore_buf_keymaps(sess.result_bufnr, config.options.keymaps.view)
  end

  -- Clear saved keymaps
  sess.saved_keymaps = nil
end

--- Setup auto-sync on file switch: automatically update diff when user edits a different file in working buffer
--- Only activates when one side is virtual (git revision) and other is working file
--- @param tabpage number Tabpage ID
--- @param original_is_virtual boolean Whether original side is virtual (git revision)
--- @param modified_is_virtual boolean Whether modified side is virtual
function M.setup_auto_sync_on_file_switch(tabpage, original_is_virtual, modified_is_virtual)
  -- Only setup if one side is virtual (commit) and other is working file
  if original_is_virtual == modified_is_virtual then
    return -- Both virtual or both real - no sync needed
  end

  local active_diffs = session.get_active_diffs()
  local sess = active_diffs[tabpage]
  if not sess then
    vim.notify("[codediff] No session found for auto-sync setup", vim.log.levels.ERROR)
    return
  end

  -- Determine which window is working
  local working_win = original_is_virtual and sess.modified_win or sess.original_win
  local working_side = original_is_virtual and "modified" or "original"

  if not working_win or not vim.api.nvim_win_is_valid(working_win) then
    vim.notify("[codediff] Working window not found for auto-sync", vim.log.levels.WARN)
    return
  end

  -- Track current file path
  local current_path = sess[working_side .. "_path"]

  -- Setup listener using BufWinEnter (fires when buffer enters window, even if existing buffer)
  local sync_group = vim.api.nvim_create_augroup("codediff_working_sync_" .. tabpage, { clear = true })

  -- Listen to BufWinEnter - fires when ANY buffer enters the window (including existing buffers)
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = sync_group,
    callback = function(args)
      -- Check if this buffer is in the working window
      local buf_win = vim.fn.bufwinid(args.buf)
      if buf_win ~= working_win then
        return
      end

      local new_path = vim.api.nvim_buf_get_name(args.buf)

      -- Skip virtual files - they're programmatic, not user navigation
      if new_path:match("^codediff://") then
        return
      end

      -- Check if file changed
      if new_path == "" or new_path == current_path then
        return
      end

      -- Update tracked path
      current_path = new_path

      -- Path changed! Need to update both sides
      vim.schedule(function()
        -- Get git root (might have changed if user switched to different repo)
        local git = require("codediff.core.git")
        local view = require("codediff.ui.view")

        git.get_git_root(new_path, function(err, new_git_root)
          if err then
            -- Not in git, just update paths without git context
            vim.schedule(function()
              -- Get relative path if possible
              local relative_path = new_path
              if sess.git_root then
                relative_path = git.get_relative_path(new_path, sess.git_root)
              end

              -- No pre-fetching needed, buffers will load content
              view.update(tabpage, {
                mode = sess.mode,
                git_root = nil,
                original_path = working_side == "original" and new_path or relative_path,
                modified_path = working_side == "modified" and new_path or relative_path,
                original_revision = working_side == "original" and nil or sess.original_revision,
                modified_revision = working_side == "modified" and nil or sess.modified_revision,
              })
            end)
            return
          end

          -- In git! Get relative path
          local relative_path = git.get_relative_path(new_path, new_git_root)

          -- No pre-fetching needed, buffers will load content
          vim.schedule(function()
            view.update(tabpage, {
              mode = sess.mode,
              git_root = new_git_root,
              original_path = relative_path,
              modified_path = relative_path,
              original_revision = sess.original_revision,
              modified_revision = sess.modified_revision,
            })
          end)
        end)
      end)
    end,
  })
end

return M
