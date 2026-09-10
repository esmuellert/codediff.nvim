-- Cleanup and autocmd management for diff views
local M = {}

local accessors = require("codediff.ui.lifecycle.accessors")
local keymaps = require("codediff.ui.lifecycle.keymaps")
local session = require("codediff.ui.lifecycle.session")
local state = require("codediff.ui.lifecycle.state")
local welcome_window = require("codediff.ui.view.welcome_window")

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

  -- Emit CodeDiffClose User autocmd
  vim.api.nvim_exec_autocmds("User", {
    pattern = "CodeDiffClose",
    modeline = false,
    data = {
      tabpage = tabpage,
      mode = accessors.event_mode(diff.panel),
    },
  })

  -- Disable auto-refresh for both buffers
  local auto_refresh = require("codediff.ui.auto_refresh")
  auto_refresh.disable(diff.original_bufnr)
  auto_refresh.disable(diff.modified_bufnr)
  if diff.result_bufnr then
    auto_refresh.disable_result(diff.result_bufnr)
  end

  -- Restore gutter options before deleting buffers can close or reuse windows.
  require("codediff.ui.conflict").teardown_gutter(tabpage)

  -- Clear highlights from both buffers
  state.clear_buffer_highlights(diff.original_bufnr)
  state.clear_buffer_highlights(diff.modified_bufnr)

  -- Restore buffer states
  state.restore_buffer_state(diff.original_bufnr, diff.original_state)
  state.restore_buffer_state(diff.modified_bufnr, diff.modified_state)

  -- Hand every mapped key back to whatever owned it before codediff
  keymaps.dispose_keymaps(tabpage)

  -- Call the panel's cleanup function to stop file watchers
  local panel_view = diff.panel and diff.panel.view
  if panel_view and panel_view._cleanup_auto_refresh then
    pcall(panel_view._cleanup_auto_refresh)
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
  if diff.original_win and vim.api.nvim_win_is_valid(diff.original_win) then
    welcome_window.apply_normal(diff.original_win)
    vim.w[diff.original_win].codediff_restore = nil
  end
  if diff.modified_win and vim.api.nvim_win_is_valid(diff.modified_win) then
    welcome_window.apply_normal(diff.modified_win)
    vim.w[diff.modified_win].codediff_restore = nil
  end

  -- Clear result window variable if exists (conflict mode)
  if diff.result_win and vim.api.nvim_win_is_valid(diff.result_win) then
    vim.w[diff.result_win].codediff_restore = nil
  end

  -- Clear conflict file tracking (buffers remain, just not tracked)
  diff.conflict_files = {}

  -- Clear tab-specific autocmd groups
  pcall(vim.api.nvim_del_augroup_by_name, "codediff_lifecycle_tab_" .. tabpage)
  pcall(vim.api.nvim_del_augroup_by_name, "codediff_working_sync_" .. tabpage)

  -- Tear down the scroll-sync group for this tab
  pcall(function()
    require("codediff.ui.scroll").teardown(tabpage)
  end)

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
            -- single_pane/inline mode: we expect only 1 diff window
            local is_single_window = diff.single_pane == true or diff.layout == "inline"
            local diff_win_count = count_diff_windows()
            local threshold = is_single_window and 0 or 1
            if diff_win_count <= threshold then
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
      vim.schedule(function()
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
      end)
    end,
  })

  -- Fallback: When entering a buffer, check if we need cleanup
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function()
      local tabpage = vim.api.nvim_get_current_tabpage()
      -- Skip scheduling work when this tab has no diff session
      if not session.get_active_diffs()[tabpage] then
        return
      end
      -- Changing the window layout is not allowed inside BufEnter (E1312), so defer
      vim.schedule(function()
        -- Bail if the user switched tabs before this ran; cleanup targets the event's tab
        if vim.api.nvim_get_current_tabpage() ~= tabpage then
          return
        end
        local diff = session.get_active_diffs()[tabpage]
        if diff then
          local diff_win_count = count_diff_windows()
          local is_single_window = diff.single_pane == true or diff.layout == "inline"
          local threshold = is_single_window and 0 or 1
          if diff_win_count <= threshold then
            cleanup_diff(tabpage)
          end
        end
      end)
    end,
  })

  -- A wiped buffer takes its mappings with it. Drop the bookkeeping so slots
  -- do not accumulate for buffers that no longer exist.
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    callback = function(args)
      if args.buf then
        require("codediff.keymap").forget_buffer(args.buf)
        for _, diff in pairs(session.get_active_diffs()) do
          if diff.keymaps then
            diff.keymaps:forget_buffer(args.buf)
          end
        end
      end
    end,
  })

  -- Re-pin panel widths on terminal/tmux resize for every active diff session
  -- (see issue #346). VimResized is editor-global, so one autocmd handles all
  -- tabs; layout.arrange() is a no-op for tabs without a session.
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      local ok_l, layout = pcall(require, "codediff.ui.layout")
      if not ok_l then
        return
      end
      for tabpage, _ in pairs(session.get_active_diffs()) do
        pcall(layout.arrange, tabpage)
      end
    end,
  })
end

-- Manual cleanup function (can be called explicitly)
function M.cleanup(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  cleanup_diff(tabpage)
end

-- Aggressive cleanup for quitting neovim from the last diff tab.
-- Deletes ALL codediff-owned buffers (explorer, scratch placeholders, virtual,
-- result) so session-persistence plugins don't save them.
local function cleanup_for_quit(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local active_diffs = session.get_active_diffs()
  local diff = active_diffs[tabpage]

  -- Collect all codediff-owned buffer numbers before cleanup_diff removes tracking
  local bufs_to_delete = {}
  if diff then
    -- Explorer / history panel buffer
    local panel_view = diff.panel and diff.panel.view
    if panel_view and panel_view.bufnr then
      bufs_to_delete[panel_view.bufnr] = true
    end
    -- Diff pane buffers (virtual AND scratch placeholders)
    if diff.original_bufnr then
      bufs_to_delete[diff.original_bufnr] = true
    end
    if diff.modified_bufnr then
      bufs_to_delete[diff.modified_bufnr] = true
    end
    -- Conflict result buffer
    if diff.result_bufnr then
      bufs_to_delete[diff.result_bufnr] = true
    end
  end

  -- Run normal cleanup first (LSP notifications, autocmds, state restore, etc.)
  cleanup_diff(tabpage)

  -- Now force-delete all collected buffers that aren't real files worth keeping
  for bufnr, _ in pairs(bufs_to_delete) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local bt = vim.bo[bufnr].buftype
      local name = vim.api.nvim_buf_get_name(bufnr)
      -- Keep real, named, on-disk file buffers; delete everything else
      local is_real_file = bt == "" and name ~= "" and vim.fn.filereadable(name) == 1
      if not is_real_file then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end
end

function M.close(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local diff = session.get_active_diffs()[tabpage]
  if not diff or not vim.api.nvim_tabpage_is_valid(tabpage) then
    return false
  end
  if not accessors.confirm_close_with_unsaved(tabpage) then
    return false
  end

  if diff.exit_on_close then
    cleanup_for_quit(tabpage)
    vim.cmd("qall")
    return true
  end

  if #vim.api.nvim_list_tabpages() == 1 then
    vim.cmd("tabnew")
  end
  local tab_nr = vim.api.nvim_tabpage_get_number(tabpage)
  vim.cmd(tab_nr .. "tabclose")
  cleanup_diff(tabpage)
  return true
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
