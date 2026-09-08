-- Updates existing side-by-side diff views.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local virtual_file = require("codediff.core.virtual_file")
local auto_refresh = require("codediff.ui.auto_refresh")
local config = require("codediff.config")
local layout = require("codediff.ui.layout")
local helpers = require("codediff.ui.view.helpers")
local readiness = require("codediff.ui.view.readiness")
local render = require("codediff.ui.view.render")
local conflict_view = require("codediff.ui.conflict.view")
local view_keymaps = require("codediff.ui.view.keymaps")
local welcome_window = require("codediff.ui.view.welcome_window")

local is_virtual_revision = helpers.is_virtual_revision
local prepare_buffer = helpers.prepare_buffer
local show_real_file_buffer = helpers.show_real_file_buffer
local open_real_file = helpers.open_real_file
local compute_and_render = render.compute_and_render
local compute_and_render_conflict = conflict_view.compute_and_render_conflict
local setup_auto_refresh = render.setup_auto_refresh
local setup_conflict_result_window = conflict_view.setup_conflict_result_window
local setup_all_keymaps = view_keymaps.setup_all_keymaps

--- Put one side's content into `win` during an update, reusing the buffer when
--- it is still alive. Unlike load_side, this has to cope with the buffer having
--- been wiped since the session was built.
--- @param win number
--- @param info table From prepare_buffer; info.bufnr is updated in place
--- @param is_virtual boolean
local function reload_side(win, info, is_virtual)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  local function edit_in_place()
    vim.api.nvim_set_current_win(win)
    vim.cmd("edit! " .. vim.fn.fnameescape(info.target))
    info.bufnr = vim.api.nvim_get_current_buf()
  end

  if info.needs_edit then
    if not is_virtual then
      info.bufnr = open_real_file(win, info.target)
    elseif info.bufnr and vim.api.nvim_buf_is_valid(info.bufnr) then
      vim.api.nvim_win_set_buf(win, info.bufnr)
      virtual_file.refresh_buffer(info.bufnr)
    else
      edit_in_place()
    end
    return
  end

  if vim.api.nvim_buf_is_valid(info.bufnr) then
    if is_virtual then
      vim.api.nvim_win_set_buf(win, info.bufnr)
    else
      show_real_file_buffer(win, info.bufnr)
    end
  elseif is_virtual then
    edit_in_place()
  else
    info.bufnr = open_real_file(win, info.target)
  end
end

--- Run `render` once every side that needs loading has loaded.
--- @param tabpage number
--- @param original_info table
--- @param modified_info table
--- @param wait_state table { original: boolean, modified: boolean }
--- @param render function
local function render_when_reloaded(tabpage, original_info, modified_info, wait_state, render)
  local awaited = {}
  if wait_state.original then
    awaited[#awaited + 1] = "original"
  end
  if wait_state.modified then
    awaited[#awaited + 1] = "modified"
  end
  if #awaited == 0 then
    return
  end

  local group = vim.api.nvim_create_augroup("CodeDiffVirtualFileUpdate_" .. tabpage, { clear = true })
  local ready = readiness.when_all(awaited, function()
    vim.schedule(render)
    vim.api.nvim_del_augroup_by_id(group)
  end)

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeDiffVirtualFileLoaded",
    callback = function(event)
      local buf = event.data and event.data.buf
      if not buf then
        return
      end
      if buf == original_info.bufnr then
        ready.done("original")
      end
      if buf == modified_info.bufnr then
        ready.done("modified")
      end
    end,
  })
end

---@param tabpage number
---@param session_config SessionConfig
---@param auto_scroll_to_first_hunk boolean?
---@return boolean
function M.update(tabpage, session_config, auto_scroll_to_first_hunk)
  -- Save current window to restore focus after update
  local saved_current_win = vim.api.nvim_get_current_win()

  -- Get existing session
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end
  session.single_side = nil

  -- Get existing buffers and windows
  local old_original_buf, old_modified_buf = lifecycle.get_buffers(tabpage)
  local original_win, modified_win = lifecycle.get_windows(tabpage)

  if not old_original_buf or not old_modified_buf then
    return false
  end
  local original_win_valid = original_win and vim.api.nvim_win_is_valid(original_win)
  local modified_win_valid = modified_win and vim.api.nvim_win_is_valid(modified_win)

  -- Rebuild the first pane from the panel when both diff windows are gone.
  if not original_win_valid and not modified_win_valid then
    original_win = helpers.open_pane_from_panel(tabpage, session)
    if not original_win then
      return false
    end
    original_win_valid = true
    session.original_win = original_win
  end

  -- Disable auto-refresh temporarily
  auto_refresh.disable(old_original_buf)
  auto_refresh.disable(old_modified_buf)

  -- Clear highlights from old buffers (before they're replaced/deleted)
  lifecycle.clear_highlights(old_original_buf)
  lifecycle.clear_highlights(old_modified_buf)

  -- Clear stored_diff_result to signal that an update is in progress
  lifecycle.update_diff_result(tabpage, nil)

  -- Retargeting can move a session between a conflicted file and an ordinary
  -- one, so the merge flag follows the incoming config.
  lifecycle.update_merge(tabpage, session_config.conflict)

  -- Handle result window when switching between conflict and non-conflict modes
  local old_result_bufnr, old_result_win = lifecycle.get_result(tabpage)
  if not session_config.conflict and old_result_win and vim.api.nvim_win_is_valid(old_result_win) then
    vim.api.nvim_win_close(old_result_win, false)
    lifecycle.set_result(tabpage, nil, nil)
  end

  -- Restore the second pane after a single-file view or a manual close.
  if session.single_pane or not original_win_valid or not modified_win_valid then
    local split_cmd = config.options.diff.original_position == "right" and "leftabove vsplit" or "rightbelow vsplit"

    if not original_win_valid then
      -- Recreate original on the configured side of modified.
      vim.api.nvim_set_current_win(modified_win)
      vim.cmd(config.options.diff.original_position == "right" and "rightbelow vsplit" or "leftabove vsplit")
      original_win = vim.api.nvim_get_current_win()
      vim.w[original_win].codediff_restore = 1
      session.original_win = original_win
    elseif not modified_win_valid then
      -- Recreate modified on the configured side of original.
      vim.api.nvim_set_current_win(original_win)
      vim.cmd(split_cmd)
      modified_win = vim.api.nvim_get_current_win()
      vim.w[modified_win].codediff_restore = 1
      session.modified_win = modified_win
    end

    -- Clear single_pane AFTER new window has codediff_restore set
    session.single_pane = nil
    layout.arrange(tabpage)
  end

  -- Determine if new buffers are virtual
  local original_is_virtual = is_virtual_revision(session_config.original_revision)
  local modified_is_virtual = is_virtual_revision(session_config.modified_revision)

  -- Prepare new buffer information
  local original_info = prepare_buffer(original_is_virtual, session_config.git_root, session_config.original_revision, session_config.original)
  local modified_info = prepare_buffer(modified_is_virtual, session_config.git_root, session_config.modified_revision, session_config.modified)

  -- Determine if we need to wait for virtual file content
  local wait_state = {
    original = original_is_virtual and original_info.needs_edit,
    modified = modified_is_virtual and modified_info.needs_edit,
  }

  local render_everything = function()
    -- Guard: Check if windows are still valid
    if not vim.api.nvim_win_is_valid(original_win) or not vim.api.nvim_win_is_valid(modified_win) then
      return
    end

    -- Guard: Check if buffers are still valid
    if not vim.api.nvim_buf_is_valid(original_info.bufnr) or not vim.api.nvim_buf_is_valid(modified_info.bufnr) then
      return
    end

    -- Always read from buffers (single source of truth)
    local original_lines = vim.api.nvim_buf_get_lines(original_info.bufnr, 0, -1, false)
    local modified_lines = vim.api.nvim_buf_get_lines(modified_info.bufnr, 0, -1, false)

    local should_auto_scroll = auto_scroll_to_first_hunk == true
    local lines_diff

    if session_config.conflict then
      -- Conflict mode: Fetch base content and render both sides against base
      local git = require("codediff.core.git")
      local base_revision = ":1"

      git.get_file_content(base_revision, session_config.git_root, session_config.original.relative, function(err, base_lines)
        if err then
          base_lines = {}
        end

        vim.schedule(function()
          local conflict_diffs =
            compute_and_render_conflict(original_info.bufnr, modified_info.bufnr, base_lines, original_lines, modified_lines, original_win, modified_win, should_auto_scroll)

          if conflict_diffs then
            lifecycle.update_buffers(tabpage, original_info.bufnr, modified_info.bufnr)
            lifecycle.update_git_root(tabpage, session_config.git_root)
            lifecycle.update_revisions(tabpage, session_config.original_revision, session_config.modified_revision)
            lifecycle.update_diff_result(tabpage, conflict_diffs.base_to_modified_diff)
            lifecycle.update_changedtick(tabpage, vim.api.nvim_buf_get_changedtick(original_info.bufnr), vim.api.nvim_buf_get_changedtick(modified_info.bufnr))
            local is_explorer_mode = session.panel and session.panel.name == "explorer"
            local success = setup_conflict_result_window(tabpage, session_config, original_win, modified_win, base_lines, conflict_diffs, true)
            if success then
              setup_all_keymaps(tabpage, original_info.bufnr, modified_info.bufnr, is_explorer_mode)
              local conflict = require("codediff.ui.conflict")
              conflict.setup_keymaps(tabpage)
            end
          end
        end)
      end)
    else
      -- Normal mode: Compute and render diff between left and right
      lines_diff = compute_and_render(
        original_info.bufnr,
        modified_info.bufnr,
        original_lines,
        modified_lines,
        original_is_virtual,
        modified_is_virtual,
        original_win,
        modified_win,
        should_auto_scroll,
        session_config.line_range
      )

      if lines_diff then
        lifecycle.update_buffers(tabpage, original_info.bufnr, modified_info.bufnr)
        lifecycle.update_git_root(tabpage, session_config.git_root)
        lifecycle.update_revisions(tabpage, session_config.original_revision, session_config.modified_revision)
        lifecycle.update_diff_result(tabpage, lines_diff)
        lifecycle.update_changedtick(tabpage, vim.api.nvim_buf_get_changedtick(original_info.bufnr), vim.api.nvim_buf_get_changedtick(modified_info.bufnr))
        setup_auto_refresh(original_info.bufnr, modified_info.bufnr, original_is_virtual, modified_is_virtual)

        local is_explorer_mode = session.panel and session.panel.name == "explorer"
        setup_all_keymaps(tabpage, original_info.bufnr, modified_info.bufnr, is_explorer_mode)

        -- Restore focus to the window that was active before update
        if saved_current_win and vim.api.nvim_win_is_valid(saved_current_win) then
          vim.api.nvim_set_current_win(saved_current_win)
        end
      end
    end
  end

  -- Wait for virtual content before rendering; real files are ready already.
  render_when_reloaded(tabpage, original_info, modified_info, wait_state, render_everything)
  reload_side(original_win, original_info, original_is_virtual)
  reload_side(modified_win, modified_info, modified_is_virtual)

  welcome_window.sync(original_win)
  welcome_window.sync(modified_win)

  -- Update lifecycle session metadata
  lifecycle.update_paths(tabpage, session_config.original, session_config.modified)

  -- Delete old virtual buffers if they were virtual AND are not reused
  if lifecycle.is_original_virtual(tabpage) and old_original_buf ~= original_info.bufnr and old_original_buf ~= modified_info.bufnr then
    pcall(vim.api.nvim_buf_delete, old_original_buf, { force = true })
  end

  if lifecycle.is_modified_virtual(tabpage) and old_modified_buf ~= modified_info.bufnr and old_modified_buf ~= original_info.bufnr then
    pcall(vim.api.nvim_buf_delete, old_modified_buf, { force = true })
  end

  -- Nothing to wait for: render now. Otherwise render_when_reloaded does it.
  if not (wait_state.original or wait_state.modified) then
    vim.schedule(render_everything)
  end

  return true
end

return M
