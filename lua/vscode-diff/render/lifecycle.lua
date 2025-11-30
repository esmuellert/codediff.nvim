-- Lifecycle management for diff views
-- Handles tracking, cleanup, and state restoration
--
-- STATE MODEL (Consolidated):
-- - Single source of truth for all diff sessions
-- - Immutable: mode, git_root, bufnr, win, revisions
-- - Mutable: suspended, stored_diff_result, changedtick, mtime, paths
-- - Access: Only through getters/setters
local M = {}

local highlights = require('vscode-diff.render.highlights')
local config = require('vscode-diff.config')
local virtual_file = require('vscode-diff.virtual_file')

-- Track active diff sessions
-- Structure: { 
--   tabpage_id = { 
--     original_bufnr, modified_bufnr, original_win, modified_win,
--     mode = "standalone" | "explorer",
--     git_root = string?,
--     original_path = string,
--     modified_path = string,
--     original_revision = string?, -- nil | "WORKING" | "STAGED" | commit_hash
--     modified_revision = string?,
--     original_state, modified_state,
--     suspended = bool,
--     stored_diff_result = table,
--     changedtick = { original = number, modified = number },
--     mtime = { original = number?, modified = number? }
--   } 
-- }
local active_diffs = {}

-- Autocmd group for cleanup
local augroup = vim.api.nvim_create_augroup('vscode_diff_lifecycle', { clear = true })

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

-- Clear highlights and extmarks from a buffer
-- @param bufnr number: Buffer number to clean
local function clear_buffer_highlights(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Clear both highlight and filler namespaces
  vim.api.nvim_buf_clear_namespace(bufnr, highlights.ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, highlights.ns_filler, 0, -1)
end

--- Clear highlights from a buffer (public API for update function)
function M.clear_highlights(bufnr)
  clear_buffer_highlights(bufnr)
end

-- Get file modification time (mtime)
local function get_file_mtime(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local bufname = vim.api.nvim_buf_get_name(bufnr)

  -- Virtual buffers don't have mtime
  if bufname:match('^vscodediff://') or bufname == '' then
    return nil
  end

  -- Get file stat
  local stat = vim.loop.fs_stat(bufname)
  return stat and stat.mtime.sec or nil
end

-- Check if a revision represents a virtual buffer
local function is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

-- Compute virtual URI from revision (not stored, computed on-demand)
local function compute_virtual_uri(git_root, revision, path)
  if not is_virtual_revision(revision) then
    return nil
  end
  return virtual_file.create_url(git_root, revision, path)
end

-- Suspend diff view (when leaving tab)
-- @param tabpage number: Tab page ID
local function suspend_diff(tabpage)
  local diff = active_diffs[tabpage]
  if not diff or diff.suspended then
    return
  end

  -- Disable auto-refresh (stop watching buffer changes)
  local auto_refresh = require('vscode-diff.auto_refresh')
  auto_refresh.disable(diff.original_bufnr)
  auto_refresh.disable(diff.modified_bufnr)

  -- Clear highlights from both buffers
  clear_buffer_highlights(diff.original_bufnr)
  clear_buffer_highlights(diff.modified_bufnr)

  -- Mark as suspended
  diff.suspended = true
end

-- Resume diff view (when entering tab)
-- @param tabpage number: Tab page ID
local function resume_diff(tabpage)
  local diff = active_diffs[tabpage]
  if not diff or not diff.suspended then
    return
  end

  -- Check if buffers still exist
  if not vim.api.nvim_buf_is_valid(diff.original_bufnr) or not vim.api.nvim_buf_is_valid(diff.modified_bufnr) then
    active_diffs[tabpage] = nil
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
    local diff_module = require('vscode-diff.diff')
    lines_diff = diff_module.compute_diff(original_lines, modified_lines)
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
    local core = require('vscode-diff.render.core')
    core.render_diff(diff.original_bufnr, diff.modified_bufnr, original_lines, modified_lines, lines_diff)

    -- Re-sync scrollbind ONLY if diff was recomputed (fillers may have changed)
    if diff_was_recomputed and vim.api.nvim_win_is_valid(diff.original_win) and vim.api.nvim_win_is_valid(diff.modified_win) then
      local current_win = vim.api.nvim_get_current_win()

      if current_win == diff.original_win or current_win == diff.modified_win then
        -- Step 1: Remember cursor position (line AND column)
        local saved_cursor = vim.api.nvim_win_get_cursor(current_win)

        -- Step 2: Reset both to line 1 (baseline)
        vim.api.nvim_win_set_cursor(diff.original_win, {1, 0})
        vim.api.nvim_win_set_cursor(diff.modified_win, {1, 0})

        -- Step 3: Re-establish scrollbind (reset sync state)
        vim.wo[diff.original_win].scrollbind = false
        vim.wo[diff.modified_win].scrollbind = false
        vim.wo[diff.original_win].scrollbind = true
        vim.wo[diff.modified_win].scrollbind = true
        
        -- Re-apply critical window options that might have been reset
        vim.wo[diff.original_win].wrap = false
        vim.wo[diff.modified_win].wrap = false

        -- Step 4: Restore cursor position with both line and column
        pcall(vim.api.nvim_win_set_cursor, diff.original_win, saved_cursor)
        pcall(vim.api.nvim_win_set_cursor, diff.modified_win, saved_cursor)
      end
    end
  end

  -- Re-enable auto-refresh for real buffers only
  local auto_refresh = require('vscode-diff.auto_refresh')

  -- Check if buffers are real files (not virtual) using revision
  local original_is_real = not is_virtual_revision(diff.original_revision)
  local modified_is_real = not is_virtual_revision(diff.modified_revision)

  if original_is_real then
    auto_refresh.enable(diff.original_bufnr)
  end

  if modified_is_real then
    auto_refresh.enable(diff.modified_bufnr)
  end

  -- Mark as active
  diff.suspended = false
end

-- Create a new diff session with metadata (before buffers/windows exist)
-- This is called FIRST by commands.lua to store git context
-- @param tabpage number: Tab page ID
-- @param mode string: "standalone" or "explorer"
-- @param git_root string?: Git repository root path
-- @param original_path string: Original file path (relative or absolute)
-- @param modified_path string: Modified file path (relative or absolute)
-- @param original_revision string?: Git revision for original (nil, "WORKING", "STAGED", or commit hash)
-- @param modified_revision string?: Git revision for modified
--- Create a new diff session with full initialization
--- @param tabpage number Tabpage ID
--- @param mode string "standalone" or "explorer"
--- @param git_root string? Git repository root
--- @param original_path string Original file path
--- @param modified_path string Modified file path
--- @param original_revision string? Git revision (nil = WORKING, or commit hash, or "STAGED")
--- @param modified_revision string? Git revision
--- @param original_bufnr number Original buffer number
--- @param modified_bufnr number Modified buffer number
--- @param original_win number Original window ID
--- @param modified_win number Modified window ID
--- @param lines_diff table Diff computation result
function M.create_session(tabpage, mode, git_root, original_path, modified_path, original_revision, modified_revision,
                          original_bufnr, modified_bufnr, original_win, modified_win, lines_diff)
  -- Save buffer states
  local original_state = save_buffer_state(original_bufnr)
  local modified_state = save_buffer_state(modified_bufnr)

  -- Create complete session in one step
  active_diffs[tabpage] = {
    -- Mode & Git Context (immutable)
    mode = mode,
    git_root = git_root,
    original_path = original_path,
    modified_path = modified_path,
    original_revision = original_revision,
    modified_revision = modified_revision,

    -- Buffers & Windows
    original_bufnr = original_bufnr,
    modified_bufnr = modified_bufnr,
    original_win = original_win,
    modified_win = modified_win,
    original_state = original_state,
    modified_state = modified_state,

    -- Lifecycle state
    suspended = false,
    stored_diff_result = lines_diff,
    changedtick = {
      original = vim.api.nvim_buf_get_changedtick(original_bufnr),
      modified = vim.api.nvim_buf_get_changedtick(modified_bufnr),
    },
    mtime = {
      original = get_file_mtime(original_bufnr),
      modified = get_file_mtime(modified_bufnr),
    },

    -- Explorer reference (only for explorer mode)
    explorer = nil,
  }

  -- Mark windows with restore flag
  vim.w[original_win].vscode_diff_restore = 1
  vim.w[modified_win].vscode_diff_restore = 1

  -- Apply inlay hint settings if configured
  if config.options.diff.disable_inlay_hints and vim.lsp.inlay_hint then
    vim.lsp.inlay_hint.enable(false, { bufnr = original_bufnr })
    vim.lsp.inlay_hint.enable(false, { bufnr = modified_bufnr })
  end

  -- Setup tab autocmds
  local tab_augroup = vim.api.nvim_create_augroup('vscode_diff_lifecycle_tab_' .. tabpage, { clear = true })

  -- Force disable winbar to prevent alignment issues
  local function ensure_no_winbar()
    if vim.api.nvim_win_is_valid(original_win) then
      vim.wo[original_win].winbar = ""
    end
    if vim.api.nvim_win_is_valid(modified_win) then
      vim.wo[modified_win].winbar = ""
    end
  end

  vim.api.nvim_create_autocmd({'BufWinEnter', 'FileType'}, {
    group = tab_augroup,
    callback = function(args)
      local win = vim.api.nvim_get_current_win()
      if win == original_win or win == modified_win then
        ensure_no_winbar()
        -- Re-apply critical window options that might get reset by ftplugins/autocmds
        vim.wo[win].wrap = false
      end
    end,
  })

  vim.api.nvim_create_autocmd('TabLeave', {
    group = tab_augroup,
    callback = function()
      local current_tab = vim.api.nvim_get_current_tabpage()
      if current_tab == tabpage then
        suspend_diff(tabpage)
      end
    end,
  })

  vim.api.nvim_create_autocmd('TabEnter', {
    group = tab_augroup,
    callback = function()
      vim.schedule(function()
        local current_tab = vim.api.nvim_get_current_tabpage()
        if current_tab == tabpage and active_diffs[tabpage] then
          resume_diff(tabpage)
        end
      end)
    end,
  })
end


-- Cleanup a specific diff session
-- @param tabpage number: Tab page ID
local function cleanup_diff(tabpage)
  local diff = active_diffs[tabpage]
  if not diff then
    return
  end

  -- Disable auto-refresh for both buffers
  local auto_refresh = require('vscode-diff.auto_refresh')
  auto_refresh.disable(diff.original_bufnr)
  auto_refresh.disable(diff.modified_bufnr)

  -- Clear highlights from both buffers
  clear_buffer_highlights(diff.original_bufnr)
  clear_buffer_highlights(diff.modified_bufnr)

  -- Restore buffer states
  restore_buffer_state(diff.original_bufnr, diff.original_state)
  restore_buffer_state(diff.modified_bufnr, diff.modified_state)

  -- Clean view keymaps from diff buffers
  for _, bufnr in ipairs({ diff.original_bufnr, diff.modified_bufnr }) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      for _, key in pairs(config.options.keymaps.view) do
        if key then
          pcall(vim.keymap.del, 'n', key, { buffer = bufnr })
        end
      end
    end
  end

  -- Clean view and explorer keymaps from explorer buffer 
  if diff.explorer and diff.explorer.bufnr and vim.api.nvim_buf_is_valid(diff.explorer.bufnr) then
    for _, key in pairs(config.options.keymaps.view) do
      if key then
        pcall(vim.keymap.del, 'n', key, { buffer = diff.explorer.bufnr })
      end
    end
    for _, key in pairs(config.options.keymaps.explorer) do
      if key then
        pcall(vim.keymap.del, 'n', key, { buffer = diff.explorer.bufnr })
      end
    end
  end

  -- Send didClose notifications for virtual buffers
  -- Compute URIs on-demand since we don't store them anymore
  local original_virtual_uri = compute_virtual_uri(diff.git_root, diff.original_revision, diff.original_path)
  local modified_virtual_uri = compute_virtual_uri(diff.git_root, diff.modified_revision, diff.modified_path)

  -- Get LSP clients from any valid buffer
  local ref_bufnr = vim.api.nvim_buf_is_valid(diff.original_bufnr) and diff.original_bufnr or diff.modified_bufnr
  local clients = vim.lsp.get_clients({ bufnr = ref_bufnr })

  for _, client in ipairs(clients) do
    if client.server_capabilities.semanticTokensProvider then
      if original_virtual_uri then
        pcall(client.notify, 'textDocument/didClose', {
          textDocument = { uri = original_virtual_uri }
        })
      end
      if modified_virtual_uri then
        pcall(client.notify, 'textDocument/didClose', {
          textDocument = { uri = modified_virtual_uri }
        })
      end
    end
  end

  -- Delete virtual buffers if they're still valid
  if vim.api.nvim_buf_is_valid(diff.original_bufnr) then
    if is_virtual_revision(diff.original_revision) then
      pcall(vim.api.nvim_buf_delete, diff.original_bufnr, { force = true })
    end
  end

  if vim.api.nvim_buf_is_valid(diff.modified_bufnr) then
    if is_virtual_revision(diff.modified_revision) then
      pcall(vim.api.nvim_buf_delete, diff.modified_bufnr, { force = true })
    end
  end

  -- Clear window variables if windows still exist
  if vim.api.nvim_win_is_valid(diff.original_win) then
    vim.w[diff.original_win].vscode_diff_restore = nil
  end
  if vim.api.nvim_win_is_valid(diff.modified_win) then
    vim.w[diff.modified_win].vscode_diff_restore = nil
  end

  -- Clear tab-specific autocmd groups
  pcall(vim.api.nvim_del_augroup_by_name, 'vscode_diff_lifecycle_tab_' .. tabpage)
  pcall(vim.api.nvim_del_augroup_by_name, 'vscode_diff_working_sync_' .. tabpage)

  -- Remove from tracking
  active_diffs[tabpage] = nil
end

-- Count windows in current tabpage that have diff markers
local function count_diff_windows()
  local count = 0
  for i = 1, vim.fn.winnr('$') do
    local win = vim.fn.win_getid(i)
    if vim.w[win].vscode_diff_restore then
      count = count + 1
    end
  end
  return count
end

-- Check if we should trigger cleanup for a window
local function should_cleanup(winid)
  return vim.w[winid].vscode_diff_restore and vim.api.nvim_win_is_valid(winid)
end

-- Setup autocmds for automatic cleanup
function M.setup_autocmds()
  -- When a window is closed, check if we should cleanup the diff
  vim.api.nvim_create_autocmd('WinClosed', {
    group = augroup,
    callback = function(args)
      local closed_win = tonumber(args.match)
      if not closed_win then
        return
      end

      -- Give Neovim a moment to update window state
      vim.schedule(function()
        -- Check if the closed window was part of a diff
        for tabpage, diff in pairs(active_diffs) do
          if diff.original_win == closed_win or diff.modified_win == closed_win then
            -- If we're down to 1 or 0 diff windows, cleanup
            local diff_win_count = count_diff_windows()
            if diff_win_count <= 1 then
              cleanup_diff(tabpage)
            end
            break
          end
        end
      end)
    end,
  })

  -- When a tab is closed, cleanup its diff
  vim.api.nvim_create_autocmd('TabClosed', {
    group = augroup,
    callback = function()
      -- TabClosed doesn't give us the tab number, so we need to scan
      -- Remove any diffs for tabs that no longer exist
      local valid_tabs = {}
      for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
        valid_tabs[tabpage] = true
      end

      for tabpage, _ in pairs(active_diffs) do
        if not valid_tabs[tabpage] then
          cleanup_diff(tabpage)
        end
      end
    end,
  })

  -- Fallback: When entering a buffer, check if we need cleanup
  vim.api.nvim_create_autocmd('BufEnter', {
    group = augroup,
    callback = function()
      local current_tab = vim.api.nvim_get_current_tabpage()
      local diff = active_diffs[current_tab]

      if diff then
        local diff_win_count = count_diff_windows()
        -- If only 1 diff window remains, the user likely closed the other side
        if diff_win_count == 1 then
          cleanup_diff(current_tab)
        end
      end
    end,
  })
end

-- Manual cleanup function (can be called explicitly)
function M.cleanup(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  cleanup_diff(tabpage)
end

-- Cleanup all active diffs (useful for plugin unload/reload)
function M.cleanup_all()
  for tabpage, _ in pairs(active_diffs) do
    cleanup_diff(tabpage)
  end
end

-- Initialize lifecycle management
function M.setup()
  M.setup_autocmds()
end

-- ============================================================================
-- PUBLIC API - GETTERS (return copies/values, safe)
-- ============================================================================

--- Get full session (deep copy for debugging)
function M.get_session(tabpage)
  local session = active_diffs[tabpage]
  if not session then return nil end
  return vim.deepcopy(session)
end

--- Get mode
function M.get_mode(tabpage)
  local session = active_diffs[tabpage]
  return session and session.mode or nil
end

--- Get git context
function M.get_git_context(tabpage)
  local session = active_diffs[tabpage]
  if not session then return nil end

  return {
    git_root = session.git_root,
    original_revision = session.original_revision,
    modified_revision = session.modified_revision,
  }
end

--- Get buffer IDs
function M.get_buffers(tabpage)
  local session = active_diffs[tabpage]
  if not session then return nil, nil end
  return session.original_bufnr, session.modified_bufnr
end

--- Get window IDs
function M.get_windows(tabpage)
  local session = active_diffs[tabpage]
  if not session then return nil, nil end
  return session.original_win, session.modified_win
end

--- Get paths
function M.get_paths(tabpage)
  local session = active_diffs[tabpage]
  if not session then return nil, nil end
  return session.original_path, session.modified_path
end

--- Find tabpage containing a buffer
function M.find_tabpage_by_buffer(bufnr)
  for tabpage, session in pairs(active_diffs) do
    if session.original_bufnr == bufnr or session.modified_bufnr == bufnr then
      return tabpage
    end
  end
  return nil
end

--- Check if original buffer is virtual
function M.is_original_virtual(tabpage)
  local session = active_diffs[tabpage]
  if not session then return false end
  return is_virtual_revision(session.original_revision)
end

--- Check if modified buffer is virtual
function M.is_modified_virtual(tabpage)
  local session = active_diffs[tabpage]
  if not session then return false end
  return is_virtual_revision(session.modified_revision)
end

--- Check if suspended
function M.is_suspended(tabpage)
  local session = active_diffs[tabpage]
  return session and session.suspended or false
end

-- ============================================================================
-- PUBLIC API - SETTERS (validated mutations)
-- ============================================================================

--- Update suspended state
function M.update_suspended(tabpage, suspended)
  local session = active_diffs[tabpage]
  if not session then return false end

  session.suspended = suspended
  return true
end

--- Update diff result (cached)
function M.update_diff_result(tabpage, diff_lines)
  local session = active_diffs[tabpage]
  if not session then return false end

  session.stored_diff_result = diff_lines
  return true
end

--- Update changedtick
function M.update_changedtick(tabpage, original_tick, modified_tick)
  local session = active_diffs[tabpage]
  if not session then return false end

  session.changedtick.original = original_tick
  session.changedtick.modified = modified_tick
  return true
end

--- Update mtime
function M.update_mtime(tabpage, original_mtime, modified_mtime)
  local session = active_diffs[tabpage]
  if not session then return false end

  session.mtime.original = original_mtime
  session.mtime.modified = modified_mtime
  return true
end

--- Update paths (for file switching/sync)
function M.update_paths(tabpage, original_path, modified_path)
  local session = active_diffs[tabpage]
  if not session then return false end

  session.original_path = original_path
  session.modified_path = modified_path
  return true
end

--- Update buffer numbers (for file switching/sync when buffers change)
--- Also updates buffer states (for suspend/resume to work correctly)
function M.update_buffers(tabpage, original_bufnr, modified_bufnr)
  local session = active_diffs[tabpage]
  if not session then return false end

  session.original_bufnr = original_bufnr
  session.modified_bufnr = modified_bufnr

  -- Save buffer states for new buffers (critical for suspend/resume!)
  session.original_state = save_buffer_state(original_bufnr)
  session.modified_state = save_buffer_state(modified_bufnr)

  return true
end

--- Update git root (for file switching when changing repos)
function M.update_git_root(tabpage, git_root)
  local session = active_diffs[tabpage]
  if not session then return false end

  session.git_root = git_root
  return true
end

--- Update revisions (for file switching/sync)
function M.update_revisions(tabpage, original_revision, modified_revision)
  local session = active_diffs[tabpage]
  if not session then return false end

  session.original_revision = original_revision
  session.modified_revision = modified_revision
  return true
end

--- Set explorer reference (for explorer mode)
function M.set_explorer(tabpage, explorer)
  local session = active_diffs[tabpage]
  if not session then return false end

  session.explorer = explorer
  return true
end

--- Get explorer reference (for explorer mode)
function M.get_explorer(tabpage)
  local session = active_diffs[tabpage]
  return session and session.explorer
end

--- Set a keymap on all buffers in the diff tab (both diff buffers + explorer)
--- This is the unified API for setting tab-wide keymaps
--- @param tabpage number Tab page ID
--- @param mode string Keymap mode ('n', 'v', etc.)
--- @param lhs string Left-hand side of the keymap
--- @param rhs function|string Right-hand side (callback or command)
--- @param opts? table Optional keymap options (will be merged with buffer-local defaults)
--- @return boolean success True if keymaps were set
function M.set_tab_keymap(tabpage, mode, lhs, rhs, opts)
  local session = active_diffs[tabpage]
  if not session then
    return false
  end

  opts = opts or {}
  local base_opts = { noremap = true, silent = true, nowait = true }

  -- Set on both diff buffers
  if vim.api.nvim_buf_is_valid(session.original_bufnr) then
    vim.keymap.set(mode, lhs, rhs, vim.tbl_extend('force', base_opts, opts, { buffer = session.original_bufnr }))
  end

  if vim.api.nvim_buf_is_valid(session.modified_bufnr) then
    vim.keymap.set(mode, lhs, rhs, vim.tbl_extend('force', base_opts, opts, { buffer = session.modified_bufnr }))
  end

  -- Set on explorer buffer if exists
  local explorer = session.explorer
  if explorer and explorer.bufnr and vim.api.nvim_buf_is_valid(explorer.bufnr) then
    vim.keymap.set(mode, lhs, rhs, vim.tbl_extend('force', base_opts, opts, { buffer = explorer.bufnr }))
  end

  return true
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

  local session = active_diffs[tabpage]
  if not session then
    vim.notify('[vscode-diff] No session found for auto-sync setup', vim.log.levels.ERROR)
    return
  end

  -- Determine which window is working
  local working_win = original_is_virtual and session.modified_win or session.original_win
  local working_side = original_is_virtual and "modified" or "original"

  if not working_win or not vim.api.nvim_win_is_valid(working_win) then
    vim.notify('[vscode-diff] Working window not found for auto-sync', vim.log.levels.WARN)
    return
  end

  -- Track current file path
  local current_path = session[working_side .. '_path']

  -- Setup listener using BufWinEnter (fires when buffer enters window, even if existing buffer)
  local sync_group = vim.api.nvim_create_augroup('vscode_diff_working_sync_' .. tabpage, { clear = true })

  -- Listen to BufWinEnter - fires when ANY buffer enters the window (including existing buffers)
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = sync_group,
    callback = function(args)
      -- Check if this buffer is in the working window
      local buf_win = vim.fn.bufwinid(args.buf)
      if buf_win ~= working_win then
        return
      end

      local new_path = vim.api.nvim_buf_get_name(args.buf)

      -- Check if file changed
      if new_path == "" or new_path == current_path then
        return
      end

      -- Update tracked path
      current_path = new_path

      -- Path changed! Need to update both sides
      vim.schedule(function()
        -- Get git root (might have changed if user switched to different repo)
        local git = require('vscode-diff.git')
        local view = require('vscode-diff.render.view')

        git.get_git_root(new_path, function(err, new_git_root)
          if err then
            -- Not in git, just update paths without git context
            vim.schedule(function()
              -- Get relative path if possible
              local relative_path = new_path
              if session.git_root then
                relative_path = git.get_relative_path(new_path, session.git_root)
              end

              -- No pre-fetching needed, buffers will load content
              view.update(tabpage,
                {
                  mode = session.mode,
                  git_root = nil,
                  original_path = working_side == "original" and new_path or relative_path,
                  modified_path = working_side == "modified" and new_path or relative_path,
                  original_revision = working_side == "original" and nil or session.original_revision,
                  modified_revision = working_side == "modified" and nil or session.modified_revision,
                })
            end)
            return
          end

          -- In git! Get relative path
          local relative_path = git.get_relative_path(new_path, new_git_root)

          -- No pre-fetching needed, buffers will load content
          vim.schedule(function()
            view.update(tabpage,
              {
                mode = session.mode,
                git_root = new_git_root,
                original_path = relative_path,
                modified_path = relative_path,
                original_revision = session.original_revision,
                modified_revision = session.modified_revision,
              })
          end)
        end)
      end)
    end,
  })
end

return M
