-- Lifecycle management for diff views
-- Handles tracking, cleanup, and state restoration
local M = {}

local highlights = require('vscode-diff.render.highlights')
local config = require('vscode-diff.config')

-- Track active diff sessions
-- Structure: { 
--   tabpage_id = { 
--     left_bufnr, right_bufnr, left_win, right_win,
--     left_virtual_uri, right_virtual_uri,  -- Cached URIs for virtual buffers (nil if real)
--     left_state, right_state,
--     suspended = bool,
--     stored_diff_result = lines_diff,  -- Only store diff result
--     changedtick = { left = number, right = number },
--     mtime = { left = number, right = number }  -- File modification time
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

-- Suspend diff view (when leaving tab)
-- @param tabpage number: Tab page ID
local function suspend_diff(tabpage)
  local diff = active_diffs[tabpage]
  if not diff or diff.suspended then
    return
  end
  
  -- Disable auto-refresh (stop watching buffer changes)
  local auto_refresh = require('vscode-diff.auto_refresh')
  auto_refresh.disable(diff.left_bufnr)
  auto_refresh.disable(diff.right_bufnr)
  
  -- Clear highlights from both buffers
  clear_buffer_highlights(diff.left_bufnr)
  clear_buffer_highlights(diff.right_bufnr)
  
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
  if not vim.api.nvim_buf_is_valid(diff.left_bufnr) or not vim.api.nvim_buf_is_valid(diff.right_bufnr) then
    active_diffs[tabpage] = nil
    return
  end
  
  -- Check if buffer or file changed while suspended
  local left_tick_changed = vim.api.nvim_buf_get_changedtick(diff.left_bufnr) ~= diff.changedtick.left
  local right_tick_changed = vim.api.nvim_buf_get_changedtick(diff.right_bufnr) ~= diff.changedtick.right
  
  local left_mtime_changed = false
  local right_mtime_changed = false
  
  if diff.mtime.left then
    local current_mtime = get_file_mtime(diff.left_bufnr)
    left_mtime_changed = current_mtime ~= diff.mtime.left
  end
  
  if diff.mtime.right then
    local current_mtime = get_file_mtime(diff.right_bufnr)
    right_mtime_changed = current_mtime ~= diff.mtime.right
  end
  
  local need_recompute = left_tick_changed or right_tick_changed or left_mtime_changed or right_mtime_changed
  
  -- Always get fresh buffer content for rendering
  local left_lines = vim.api.nvim_buf_get_lines(diff.left_bufnr, 0, -1, false)
  local right_lines = vim.api.nvim_buf_get_lines(diff.right_bufnr, 0, -1, false)
  
  local lines_diff
  local diff_was_recomputed = false
  
  if need_recompute or not diff.stored_diff_result then
    -- Buffer or file changed, recompute diff
    local diff_module = require('vscode-diff.diff')
    lines_diff = diff_module.compute_diff(left_lines, right_lines)
    diff_was_recomputed = true
    
    if lines_diff then
      -- Store new diff result
      diff.stored_diff_result = lines_diff
      
      -- Update changedtick and mtime
      diff.changedtick.left = vim.api.nvim_buf_get_changedtick(diff.left_bufnr)
      diff.changedtick.right = vim.api.nvim_buf_get_changedtick(diff.right_bufnr)
      diff.mtime.left = get_file_mtime(diff.left_bufnr)
      diff.mtime.right = get_file_mtime(diff.right_bufnr)
    end
  else
    -- Nothing changed, reuse stored diff result
    lines_diff = diff.stored_diff_result
  end
  
  -- Render with fresh content and (possibly reused) diff result
  if lines_diff then
    local core = require('vscode-diff.render.core')
    core.render_diff(diff.left_bufnr, diff.right_bufnr, left_lines, right_lines, lines_diff)
    
    -- Re-sync scrollbind ONLY if diff was recomputed (fillers may have changed)
    if diff_was_recomputed and vim.api.nvim_win_is_valid(diff.left_win) and vim.api.nvim_win_is_valid(diff.right_win) then
      local current_win = vim.api.nvim_get_current_win()
      
      if current_win == diff.left_win or current_win == diff.right_win then
        -- Step 1: Remember cursor position after render
        local saved_line = vim.api.nvim_win_get_cursor(current_win)[1]
        
        -- Step 2: Reset both to line 1 (baseline)
        vim.api.nvim_win_set_cursor(diff.left_win, {1, 0})
        vim.api.nvim_win_set_cursor(diff.right_win, {1, 0})
        
        -- Step 3: Re-establish scrollbind (reset sync state)
        vim.wo[diff.left_win].scrollbind = false
        vim.wo[diff.right_win].scrollbind = false
        vim.wo[diff.left_win].scrollbind = true
        vim.wo[diff.right_win].scrollbind = true
        
        -- Step 4: Set both to saved line (like initial creation)
        pcall(vim.api.nvim_win_set_cursor, diff.left_win, {saved_line, 0})
        pcall(vim.api.nvim_win_set_cursor, diff.right_win, {saved_line, 0})
      end
    end
  end
  
  -- Re-enable auto-refresh for real buffers only
  local auto_refresh = require('vscode-diff.auto_refresh')
  
  -- Check if buffers are real files (not virtual)
  local left_name = vim.api.nvim_buf_get_name(diff.left_bufnr)
  local right_name = vim.api.nvim_buf_get_name(diff.right_bufnr)
  
  local left_is_real = not left_name:match('^vscodediff://')
  local right_is_real = not right_name:match('^vscodediff://')
  
  if left_is_real then
    auto_refresh.enable(diff.left_bufnr, diff.left_bufnr, diff.right_bufnr)
  end
  
  if right_is_real then
    auto_refresh.enable(diff.right_bufnr, diff.left_bufnr, diff.right_bufnr)
  end
  
  -- Mark as active
  diff.suspended = false
end

-- Setup lifecycle tracking for a new diff view
-- @param tabpage number: Tab page ID
-- @param left_bufnr number: Left buffer number
-- @param right_bufnr number: Right buffer number
-- @param left_win number: Left window ID
-- @param right_win number: Right window ID
-- @param original_lines table: Original buffer lines
-- @param modified_lines table: Modified buffer lines
-- @param lines_diff table: Diff result
function M.register(tabpage, left_bufnr, right_bufnr, left_win, right_win, original_lines, modified_lines, lines_diff)
  -- Save state before modifying buffers
  local left_state = save_buffer_state(left_bufnr)
  local right_state = save_buffer_state(right_bufnr)
  
  -- Cache virtual buffer URIs NOW before they get deleted
  -- This is needed to send didClose notification even after buffer deletion
  local left_virtual_uri = nil
  local right_virtual_uri = nil
  
  if vim.api.nvim_buf_is_valid(left_bufnr) then
    local bufname = vim.api.nvim_buf_get_name(left_bufnr)
    if bufname:match('^vscodediff://') then
      left_virtual_uri = vim.uri_from_bufnr(left_bufnr)
    end
  end
  
  if vim.api.nvim_buf_is_valid(right_bufnr) then
    local bufname = vim.api.nvim_buf_get_name(right_bufnr)
    if bufname:match('^vscodediff://') then
      right_virtual_uri = vim.uri_from_bufnr(right_bufnr)
    end
  end
  
  active_diffs[tabpage] = {
    left_bufnr = left_bufnr,
    right_bufnr = right_bufnr,
    left_win = left_win,
    right_win = right_win,
    left_virtual_uri = left_virtual_uri,
    right_virtual_uri = right_virtual_uri,
    left_state = left_state,
    right_state = right_state,
    suspended = false,
    stored_diff_result = lines_diff,  -- Only store diff result
    changedtick = {
      left = vim.api.nvim_buf_get_changedtick(left_bufnr),
      right = vim.api.nvim_buf_get_changedtick(right_bufnr),
    },
    mtime = {
      left = get_file_mtime(left_bufnr),
      right = get_file_mtime(right_bufnr),
    },
  }
  
  -- Mark windows with our restore flag (similar to vim-fugitive)
  vim.w[left_win].vscode_diff_restore = 1
  vim.w[right_win].vscode_diff_restore = 1
  
  -- Apply inlay hint settings if configured
  if config.options.diff.disable_inlay_hints and vim.lsp.inlay_hint then
    vim.lsp.inlay_hint.enable(false, { bufnr = left_bufnr })
    vim.lsp.inlay_hint.enable(false, { bufnr = right_bufnr })
  end
  
  -- Setup TabLeave autocmd to suspend when leaving this tab
  vim.api.nvim_create_autocmd('TabLeave', {
    group = augroup,
    callback = function()
      local current_tab = vim.api.nvim_get_current_tabpage()
      if current_tab == tabpage then
        suspend_diff(tabpage)
      end
    end,
  })
  
  -- Setup TabEnter autocmd to resume when entering this tab
  vim.api.nvim_create_autocmd('TabEnter', {
    group = augroup,
    callback = function()
      -- TabEnter fires when entering ANY tab, we need to check if it's our diff tab
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
  auto_refresh.disable(diff.left_bufnr)
  auto_refresh.disable(diff.right_bufnr)

  -- Clear highlights from both buffers
  clear_buffer_highlights(diff.left_bufnr)
  clear_buffer_highlights(diff.right_bufnr)
  
  -- Restore buffer states
  restore_buffer_state(diff.left_bufnr, diff.left_state)
  restore_buffer_state(diff.right_bufnr, diff.right_state)
  
  -- Send didClose notifications for virtual buffers
  -- This prevents "already open" errors when reopening same file in diff
  -- Uses cached URIs since buffers might already be deleted at cleanup time
  
  -- Get LSP clients from any valid buffer
  local ref_bufnr = vim.api.nvim_buf_is_valid(diff.left_bufnr) and diff.left_bufnr or diff.right_bufnr
  local clients = vim.lsp.get_clients({ bufnr = ref_bufnr })
  
  for _, client in ipairs(clients) do
    if client.server_capabilities.semanticTokensProvider then
      if diff.left_virtual_uri then
        pcall(client.notify, 'textDocument/didClose', {
          textDocument = { uri = diff.left_virtual_uri }
        })
      end
      if diff.right_virtual_uri then
        pcall(client.notify, 'textDocument/didClose', {
          textDocument = { uri = diff.right_virtual_uri }
        })
      end
    end
  end
  
  -- Delete virtual buffers if they're still valid
  if vim.api.nvim_buf_is_valid(diff.left_bufnr) then
    local bufname = vim.api.nvim_buf_get_name(diff.left_bufnr)
    if bufname:match('^vscodediff://') then
      pcall(vim.api.nvim_buf_delete, diff.left_bufnr, { force = true })
    end
  end
  
  if vim.api.nvim_buf_is_valid(diff.right_bufnr) then
    local bufname = vim.api.nvim_buf_get_name(diff.right_bufnr)
    if bufname:match('^vscodediff://') then
      pcall(vim.api.nvim_buf_delete, diff.right_bufnr, { force = true })
    end
  end
  
  -- Clear window variables if windows still exist
  if vim.api.nvim_win_is_valid(diff.left_win) then
    vim.w[diff.left_win].vscode_diff_restore = nil
  end
  if vim.api.nvim_win_is_valid(diff.right_win) then
    vim.w[diff.right_win].vscode_diff_restore = nil
  end
  
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
          if diff.left_win == closed_win or diff.right_win == closed_win then
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

return M
