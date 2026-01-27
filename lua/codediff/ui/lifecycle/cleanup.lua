-- Cleanup and autocmd management for diff views
local M = {}

local accessors = require("codediff.ui.lifecycle.accessors")

-- Will be injected by init.lua
local session = nil
local state = nil
M._set_session_module = function(s)
  session = s
end
M._set_state_module = function(s)
  state = s
end

-- Autocmd group for cleanup
local augroup = vim.api.nvim_create_augroup("codediff_lifecycle", { clear = true })

-- Check if a revision represents a virtual buffer
local function is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

-- Cleanup a specific diff session
-- @param tabpage number: Tab page ID
local function cleanup_diff(tabpage)
  local active_diffs = session.get_active_diffs()
  local diff = active_diffs[tabpage]
  if not diff then
    return
  end

  -- Disable auto-refresh for both buffers
  local auto_refresh = require("codediff.ui.auto_refresh")
  auto_refresh.disable(diff.original_bufnr)
  auto_refresh.disable(diff.modified_bufnr)

  -- Clear highlights from both buffers
  state.clear_buffer_highlights(diff.original_bufnr)
  state.clear_buffer_highlights(diff.modified_bufnr)

  -- Restore buffer states
  state.restore_buffer_state(diff.original_bufnr, diff.original_state)
  state.restore_buffer_state(diff.modified_bufnr, diff.modified_state)

  -- Remove tab-scoped keymaps from all tracked buffers
  accessors.clear_tab_keymaps(tabpage)

  -- Call explorer's cleanup function to stop file watchers
  if diff.explorer and diff.explorer._cleanup_auto_refresh then
    pcall(diff.explorer._cleanup_auto_refresh)
  end

  -- Send didClose notifications for virtual buffers
  -- Compute URIs on-demand since we don't store them anymore
  local original_virtual_uri = session.compute_virtual_uri(diff.git_root, diff.original_revision, diff.original_path)
  local modified_virtual_uri = session.compute_virtual_uri(diff.git_root, diff.modified_revision, diff.modified_path)

  -- Get LSP clients from any valid buffer
  local ref_bufnr = vim.api.nvim_buf_is_valid(diff.original_bufnr) and diff.original_bufnr or diff.modified_bufnr
  local clients = vim.lsp.get_clients({ bufnr = ref_bufnr })

  for _, client in ipairs(clients) do
    if client.server_capabilities.semanticTokensProvider then
      if original_virtual_uri then
        pcall(client.notify, "textDocument/didClose", {
          textDocument = { uri = original_virtual_uri },
        })
      end
      if modified_virtual_uri then
        pcall(client.notify, "textDocument/didClose", {
          textDocument = { uri = modified_virtual_uri },
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
    vim.w[diff.original_win].codediff_restore = nil
  end
  if vim.api.nvim_win_is_valid(diff.modified_win) then
    vim.w[diff.modified_win].codediff_restore = nil
  end

  -- Clear result window variable if exists (conflict mode)
  if diff.result_win and vim.api.nvim_win_is_valid(diff.result_win) then
    vim.w[diff.result_win].codediff_restore = nil
  end

  -- Clear result buffer signs (conflict mode)
  if diff.result_bufnr and vim.api.nvim_buf_is_valid(diff.result_bufnr) then
    local result_signs_ns = vim.api.nvim_create_namespace("codediff-result-signs")
    vim.api.nvim_buf_clear_namespace(diff.result_bufnr, result_signs_ns, 0, -1)
  end

  -- Clear conflict file tracking (buffers remain, just not tracked)
  diff.conflict_files = {}

  -- Clear tab-specific autocmd groups
  pcall(vim.api.nvim_del_augroup_by_name, "codediff_lifecycle_tab_" .. tabpage)
  pcall(vim.api.nvim_del_augroup_by_name, "codediff_working_sync_" .. tabpage)
  pcall(vim.api.nvim_del_augroup_by_name, "CodeDiffConflictSigns_" .. tabpage)

  -- Remove from tracking
  active_diffs[tabpage] = nil
end

-- Count windows in current tabpage that have diff markers
local function count_diff_windows()
  local count = 0
  for i = 1, vim.fn.winnr("$") do
    local win = vim.fn.win_getid(i)
    if vim.w[win].codediff_restore then
      count = count + 1
    end
  end
  return count
end

-- Check if we should trigger cleanup for a window
local function should_cleanup(winid)
  return vim.w[winid].codediff_restore and vim.api.nvim_win_is_valid(winid)
end

-- Setup autocmds for automatic cleanup
function M.setup_autocmds()
  -- When a window is closed, check if we should cleanup the diff
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(args)
      local closed_win = tonumber(args.match)
      if not closed_win then
        return
      end

      -- Give Neovim a moment to update window state
      vim.schedule(function()
        -- Check if the closed window was part of a diff
        local active_diffs = session.get_active_diffs()
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
  vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    callback = function()
      -- TabClosed doesn't give us the tab number, so we need to scan
      -- Remove any diffs for tabs that no longer exist
      local valid_tabs = {}
      for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
        valid_tabs[tabpage] = true
      end

      local active_diffs = session.get_active_diffs()
      for tabpage, _ in pairs(active_diffs) do
        if not valid_tabs[tabpage] then
          cleanup_diff(tabpage)
        end
      end
    end,
  })

  -- Fallback: When entering a buffer, check if we need cleanup
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function()
      local current_tab = vim.api.nvim_get_current_tabpage()
      local active_diffs = session.get_active_diffs()
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
  local active_diffs = session.get_active_diffs()
  for tabpage, _ in pairs(active_diffs) do
    cleanup_diff(tabpage)
  end
end

-- Initialize lifecycle management
function M.setup()
  M.setup_autocmds()
end

return M
