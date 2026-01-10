-- Diff view creation and window management
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local virtual_file = require("codediff.core.virtual_file")
local auto_refresh = require("codediff.ui.auto_refresh")
local config = require("codediff.config")

-- Import submodules
local helpers = require("codediff.ui.view.helpers")
local render = require("codediff.ui.view.render")
local view_keymaps = require("codediff.ui.view.keymaps")
local conflict_window = require("codediff.ui.view.conflict_window")

-- Re-export helper functions for backward compatibility
local is_virtual_revision = helpers.is_virtual_revision
local prepare_buffer = helpers.prepare_buffer
local compute_and_render = render.compute_and_render
local compute_and_render_conflict = render.compute_and_render_conflict
local setup_auto_refresh = render.setup_auto_refresh
local setup_conflict_result_window = conflict_window.setup_conflict_result_window
local setup_all_keymaps = view_keymaps.setup_all_keymaps

---@class SessionConfig
---@field mode "standalone"|"explorer"
---@field git_root string?
---@field original_path string
---@field modified_path string
---@field original_revision string?
---@field modified_revision string?
---@field conflict boolean? For merge conflict mode: render both sides against base
---@field explorer_data table? For explorer mode: { status_result }

---@param session_config SessionConfig Session configuration
---@param filetype? string Optional filetype for syntax highlighting
---@param on_ready? function Optional callback when view is fully ready (for sync callers)
---@return table|nil Result containing diff metadata, or nil if deferred
function M.create(session_config, filetype, on_ready)
  -- Create new tab (both modes create a tab)
  vim.cmd("tabnew")

  local tabpage = vim.api.nvim_get_current_tabpage()

  -- For explorer mode with empty paths OR dir mode (git_root == nil with explorer_data),
  -- create empty panes and skip buffer setup
  local is_explorer_placeholder = session_config.mode == "explorer"
    and ((session_config.original_path == "" or session_config.original_path == nil) or (not session_config.git_root and session_config.explorer_data))

  local original_win, modified_win, original_info, modified_info, initial_buf

  if is_explorer_placeholder then
    -- Explorer mode: Create empty split panes, skip buffer loading
    -- Explorer will populate via first file selection
    initial_buf = vim.api.nvim_get_current_buf()
    original_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    modified_win = vim.api.nvim_get_current_win()

    -- Create placeholder buffer info (will be updated by explorer)
    original_info = { bufnr = vim.api.nvim_win_get_buf(original_win) }
    modified_info = { bufnr = vim.api.nvim_win_get_buf(modified_win) }
  else
    -- Normal mode: Full buffer setup
    local original_is_virtual = is_virtual_revision(session_config.original_revision)
    local modified_is_virtual = is_virtual_revision(session_config.modified_revision)

    original_info = prepare_buffer(original_is_virtual, session_config.git_root, session_config.original_revision, session_config.original_path)
    modified_info = prepare_buffer(modified_is_virtual, session_config.git_root, session_config.modified_revision, session_config.modified_path)

    initial_buf = vim.api.nvim_get_current_buf()
    original_win = vim.api.nvim_get_current_win()

    -- Load original buffer
    if original_info.needs_edit then
      local cmd = original_is_virtual and "edit! " or "edit "
      vim.cmd(cmd .. vim.fn.fnameescape(original_info.target))
      original_info.bufnr = vim.api.nvim_get_current_buf()
    else
      vim.api.nvim_win_set_buf(original_win, original_info.bufnr)
    end

    vim.cmd("vsplit")
    modified_win = vim.api.nvim_get_current_win()

    -- Load modified buffer
    if modified_info.needs_edit then
      local cmd = modified_is_virtual and "edit! " or "edit "
      vim.cmd(cmd .. vim.fn.fnameescape(modified_info.target))
      modified_info.bufnr = vim.api.nvim_get_current_buf()
    else
      vim.api.nvim_win_set_buf(modified_win, modified_info.bufnr)
    end
  end

  -- Clean up initial buffer
  if vim.api.nvim_buf_is_valid(initial_buf) and initial_buf ~= original_info.bufnr and initial_buf ~= modified_info.bufnr then
    pcall(vim.api.nvim_buf_delete, initial_buf, { force = true })
  end

  -- Window options (scrollbind will be set by compute_and_render)
  -- Note: number and relativenumber are intentionally NOT set to honor user's local config
  local win_opts = {
    cursorline = true,
    wrap = false,
  }

  for opt, val in pairs(win_opts) do
    vim.wo[original_win][opt] = val
    vim.wo[modified_win][opt] = val
  end

  -- Note: Filetype is automatically detected when using :edit for real files
  -- For virtual files, filetype is set in the virtual_file module

  -- For explorer placeholder, create minimal session without rendering
  if is_explorer_placeholder then
    -- Create minimal lifecycle session for explorer (update will populate it)
    lifecycle.create_session(
      tabpage,
      session_config.mode,
      session_config.git_root,
      "", -- Empty paths indicate placeholder
      "",
      nil,
      nil,
      original_info.bufnr,
      modified_info.bufnr,
      original_win,
      modified_win,
      {} -- Empty diff result - will be updated on first file selection
    )
  else
    -- Normal mode: Full rendering
    local has_virtual_buffer = is_virtual_revision(session_config.original_revision) or is_virtual_revision(session_config.modified_revision)
    local original_is_virtual = is_virtual_revision(session_config.original_revision)
    local modified_is_virtual = is_virtual_revision(session_config.modified_revision)

    -- Set up rendering after buffers are ready
    local render_everything = function()
      -- Guard: Check if windows are still valid (they may have been closed during async wait)
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

      if session_config.conflict then
        -- Conflict mode: Fetch base content and render both sides against base
        local git = require("codediff.core.git")
        local base_revision = ":1"

        git.get_file_content(base_revision, session_config.git_root, session_config.original_path, function(err, base_lines)
          -- For add/add conflicts (AA), there's no base version - use empty base
          if err then
            base_lines = {}
          end

          vim.schedule(function()
            local conflict_diffs = compute_and_render_conflict(
              original_info.bufnr,
              modified_info.bufnr,
              base_lines,
              original_lines,
              modified_lines,
              original_win,
              modified_win,
              true -- auto_scroll_to_first_hunk = true on create
            )

            if conflict_diffs then
              -- Create lifecycle session for conflict mode
              lifecycle.create_session(
                tabpage,
                session_config.mode,
                session_config.git_root,
                session_config.original_path,
                session_config.modified_path,
                session_config.original_revision,
                session_config.modified_revision,
                original_info.bufnr,
                modified_info.bufnr,
                original_win,
                modified_win,
                conflict_diffs.base_to_modified_diff
              )

              -- Setup auto-refresh for consistency (both buffers are virtual in conflict mode)
              setup_auto_refresh(original_info.bufnr, modified_info.bufnr, true, true)

              -- Setup result window and keymaps
              local success = setup_conflict_result_window(tabpage, session_config, original_win, modified_win, base_lines, conflict_diffs, false)
              if success then
                setup_all_keymaps(tabpage, original_info.bufnr, modified_info.bufnr, false)
                -- Setup conflict keymaps AFTER setup_all_keymaps to override do/dp
                local conflict = require("codediff.ui.conflict")
                conflict.setup_keymaps(tabpage)
              end

              -- Signal that view is ready
              if on_ready then
                on_ready()
              end
            end
          end)
        end)
      else
        -- Normal mode: Compute and render diff between left and right
        local lines_diff = compute_and_render(
          original_info.bufnr,
          modified_info.bufnr,
          original_lines,
          modified_lines,
          original_is_virtual,
          modified_is_virtual,
          original_win,
          modified_win,
          true -- auto_scroll_to_first_hunk = true on create
        )

        if lines_diff then
          -- Create complete lifecycle session (one step!)
          lifecycle.create_session(
            tabpage,
            session_config.mode,
            session_config.git_root,
            session_config.original_path,
            session_config.modified_path,
            session_config.original_revision,
            session_config.modified_revision,
            original_info.bufnr,
            modified_info.bufnr,
            original_win,
            modified_win,
            lines_diff
          )

          -- Enable auto-refresh for real file buffers only
          setup_auto_refresh(original_info.bufnr, modified_info.bufnr, original_is_virtual, modified_is_virtual)

          -- Setup all keymaps in one place (centralized)
          setup_all_keymaps(tabpage, original_info.bufnr, modified_info.bufnr, false)

          -- Setup auto-sync on file switch (after session is complete!)
          lifecycle.setup_auto_sync_on_file_switch(tabpage, original_is_virtual, modified_is_virtual)

          -- Signal that view is ready
          if on_ready then
            on_ready()
          end
        end
      end
    end

    -- Choose timing based on buffer types
    -- Since we force reload virtual files, we ALWAYS wait for the load event if virtual files exist
    local has_virtual = original_is_virtual or modified_is_virtual

    if has_virtual then
      -- Virtual file(s): Wait for BufReadCmd to load content
      local group = vim.api.nvim_create_augroup("CodeDiffVirtualFileHighlight_" .. tabpage, { clear = true })

      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "CodeDiffVirtualFileLoaded",
        callback = function(event)
          if not event.data or not event.data.buf then
            return
          end

          local loaded_buf = event.data.buf

          -- Check if this is one of our virtual buffers
          -- We don't need complex state tracking anymore because we know they WILL load
          local all_loaded = true

          -- Check if original is virtual and loaded
          if original_is_virtual then
            -- We can't easily check "is loaded" without state, but we can check if THIS event matches
            -- For simplicity in this event-driven model, we'll use a small state tracker just for this closure
          end
        end,
      })

      -- Re-implementing the simple tracker locally
      local loaded_buffers = {}

      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "CodeDiffVirtualFileLoaded",
        callback = function(event)
          if not event.data or not event.data.buf then
            return
          end
          local loaded_buf = event.data.buf

          if (original_is_virtual and loaded_buf == original_info.bufnr) or (modified_is_virtual and loaded_buf == modified_info.bufnr) then
            loaded_buffers[loaded_buf] = true

            local ready = true
            if original_is_virtual and not loaded_buffers[original_info.bufnr] then
              ready = false
            end
            if modified_is_virtual and not loaded_buffers[modified_info.bufnr] then
              ready = false
            end

            if ready then
              vim.schedule(render_everything)
              vim.api.nvim_del_augroup_by_id(group)
            end
          end
        end,
      })
    else
      -- Real files only: Defer until :edit completes
      vim.schedule(render_everything)
    end
  end

  -- For explorer mode, create the explorer sidebar after diff windows are set up
  if session_config.mode == "explorer" and session_config.explorer_data then
    -- Get explorer position from config
    local explorer_config = config.options.explorer or {}
    local position = explorer_config.position or "left"

    -- Create explorer (explorer manages its own lifecycle and callbacks)
    local explorer = require("codediff.ui.explorer")
    local status_result = session_config.explorer_data.status_result

    -- For dir mode (git_root == nil), pass original_path and modified_path as dir roots
    local explorer_opts = nil
    if not session_config.git_root then
      explorer_opts = {
        dir1 = session_config.original_path,
        dir2 = session_config.modified_path,
      }
    end

    local explorer_obj = explorer.create(status_result, session_config.git_root, tabpage, nil, session_config.original_revision, session_config.modified_revision, explorer_opts)

    -- Store explorer reference in lifecycle
    lifecycle.set_explorer(tabpage, explorer_obj)

    -- Note: Keymaps will be set when first file is selected via update()

    -- Adjust diff window sizes based on explorer position
    if position == "bottom" then
      -- For bottom position, diff windows take full width, equalize them
      vim.cmd("wincmd =")
    else
      -- For left position, calculate remaining width and split equally
      local total_width = vim.o.columns
      local explorer_width = explorer_config.width or 40
      local remaining_width = total_width - explorer_width
      local diff_width = math.floor(remaining_width / 2)

      vim.api.nvim_win_set_width(original_win, diff_width)
      vim.api.nvim_win_set_width(modified_win, diff_width)
    end
  end

  return {
    original_buf = original_info.bufnr,
    modified_buf = modified_info.bufnr,
    original_win = original_win,
    modified_win = modified_win,
  }
end

---Update existing diff view with new files/revisions
---@param tabpage number Tabpage ID of the diff session
---@param session_config SessionConfig New session configuration (updates both sides)
---@param auto_scroll_to_first_hunk boolean? Whether to auto-scroll to first hunk (default: false)
---@return boolean success Whether update succeeded
function M.update(tabpage, session_config, auto_scroll_to_first_hunk)
  -- Get existing session
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("No diff session found for tabpage", vim.log.levels.ERROR)
    return false
  end

  -- Get existing buffers and windows
  local old_original_buf, old_modified_buf = lifecycle.get_buffers(tabpage)
  local original_win, modified_win = lifecycle.get_windows(tabpage)

  if not old_original_buf or not old_modified_buf or not original_win or not modified_win then
    vim.notify("Invalid diff session state", vim.log.levels.ERROR)
    return false
  end

  -- Disable auto-refresh temporarily
  auto_refresh.disable(old_original_buf)
  auto_refresh.disable(old_modified_buf)

  -- Clear highlights from old buffers (before they're replaced/deleted)
  lifecycle.clear_highlights(old_original_buf)
  lifecycle.clear_highlights(old_modified_buf)

  -- Clear stored_diff_result to signal that an update is in progress
  -- This allows wait_for_session_ready to detect pending updates
  lifecycle.update_diff_result(tabpage, nil)

  -- Handle result window when switching between conflict and non-conflict modes
  local old_result_bufnr, old_result_win = lifecycle.get_result(tabpage)
  if not session_config.conflict and old_result_win and vim.api.nvim_win_is_valid(old_result_win) then
    -- Switching to non-conflict mode: close the result window
    -- The buffer remains (real file), just close the window
    vim.api.nvim_win_close(old_result_win, false)
    lifecycle.set_result(tabpage, nil, nil)
  end

  -- Determine if new buffers are virtual
  local original_is_virtual = is_virtual_revision(session_config.original_revision)
  local modified_is_virtual = is_virtual_revision(session_config.modified_revision)

  -- Prepare new buffer information
  local original_info = prepare_buffer(original_is_virtual, session_config.git_root, session_config.original_revision, session_config.original_path)
  local modified_info = prepare_buffer(modified_is_virtual, session_config.git_root, session_config.modified_revision, session_config.modified_path)

  -- Determine if we need to wait for virtual file content
  -- Since we force reload virtual files, we always wait for the load event
  -- Use a state table to avoid closure capture issues in autocmd
  local wait_state = {
    original = original_is_virtual and original_info.needs_edit,
    modified = modified_is_virtual and modified_info.needs_edit,
  }

  local render_everything = function()
    -- Guard: Check if windows are still valid (they may have been closed during async wait)
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

    -- Use the provided auto_scroll parameter, default to false if not specified
    local should_auto_scroll = auto_scroll_to_first_hunk == true
    local lines_diff

    if session_config.conflict then
      -- Conflict mode: Fetch base content and render both sides against base
      local git = require("codediff.core.git")
      local base_revision = ":1"

      git.get_file_content(base_revision, session_config.git_root, session_config.original_path, function(err, base_lines)
        -- For add/add conflicts (AA), there's no base version - use empty base
        if err then
          base_lines = {}
        end

        vim.schedule(function()
          local conflict_diffs =
            compute_and_render_conflict(original_info.bufnr, modified_info.bufnr, base_lines, original_lines, modified_lines, original_win, modified_win, should_auto_scroll)

          if conflict_diffs then
            -- Update lifecycle session with conflict diff info
            lifecycle.update_buffers(tabpage, original_info.bufnr, modified_info.bufnr)
            lifecycle.update_git_root(tabpage, session_config.git_root)
            lifecycle.update_revisions(tabpage, session_config.original_revision, session_config.modified_revision)
            lifecycle.update_diff_result(tabpage, conflict_diffs.base_to_modified_diff)
            lifecycle.update_changedtick(tabpage, vim.api.nvim_buf_get_changedtick(original_info.bufnr), vim.api.nvim_buf_get_changedtick(modified_info.bufnr))

            -- Setup auto-refresh for consistency (both buffers are virtual in conflict mode)
            setup_auto_refresh(original_info.bufnr, modified_info.bufnr, true, true)

            -- Setup result window and keymaps
            local is_explorer_mode = session.mode == "explorer"
            local success = setup_conflict_result_window(tabpage, session_config, original_win, modified_win, base_lines, conflict_diffs, true)
            if success then
              setup_all_keymaps(tabpage, original_info.bufnr, modified_info.bufnr, is_explorer_mode)
              -- Setup conflict keymaps AFTER setup_all_keymaps to override do/dp
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
        should_auto_scroll
      )

      if lines_diff then
        -- Update lifecycle session with all new state
        lifecycle.update_buffers(tabpage, original_info.bufnr, modified_info.bufnr)
        lifecycle.update_git_root(tabpage, session_config.git_root)
        lifecycle.update_revisions(tabpage, session_config.original_revision, session_config.modified_revision)
        lifecycle.update_diff_result(tabpage, lines_diff)
        lifecycle.update_changedtick(tabpage, vim.api.nvim_buf_get_changedtick(original_info.bufnr), vim.api.nvim_buf_get_changedtick(modified_info.bufnr))

        -- Re-enable auto-refresh for real file buffers
        setup_auto_refresh(original_info.bufnr, modified_info.bufnr, original_is_virtual, modified_is_virtual)

        -- Setup all keymaps in one place (centralized)
        local is_explorer_mode = session.mode == "explorer"
        setup_all_keymaps(tabpage, original_info.bufnr, modified_info.bufnr, is_explorer_mode)
      end
    end
  end

  -- Set up autocmd to wait for virtual file loads BEFORE triggering any async operations
  -- This prevents race conditions where fast systems complete before the listener is ready
  local autocmd_group = nil
  if wait_state.original or wait_state.modified then
    autocmd_group = vim.api.nvim_create_augroup("CodeDiffVirtualFileUpdate_" .. tabpage, { clear = true })

    vim.api.nvim_create_autocmd("User", {
      group = autocmd_group,
      pattern = "CodeDiffVirtualFileLoaded",
      callback = function(event)
        if not event.data or not event.data.buf then
          return
        end

        local loaded_buf = event.data.buf

        -- Mark buffers as loaded when event fires
        if wait_state.original and loaded_buf == original_info.bufnr then
          wait_state.original = false
        end
        if wait_state.modified and loaded_buf == modified_info.bufnr then
          wait_state.modified = false
        end

        -- Render once all waited buffers are ready
        if not wait_state.original and not wait_state.modified then
          vim.schedule(render_everything)
          vim.api.nvim_del_augroup_by_id(autocmd_group)
        end
      end,
    })
  end

  -- Load buffers into windows
  -- For existing buffers: use nvim_win_set_buf() directly (no conflicts, no temp buffers needed)
  -- For new virtual files: use :edit! to trigger BufReadCmd for content loading
  -- For new real files: use bufadd + bufload + nvim_win_set_buf

  if vim.api.nvim_win_is_valid(original_win) then
    if original_info.needs_edit then
      if original_is_virtual then
        -- For virtual files with mutable revisions (:0, :1, :2, :3)
        -- Check if buffer already exists and just needs content refresh
        if original_info.bufnr and vim.api.nvim_buf_is_valid(original_info.bufnr) then
          -- Buffer exists, just refresh its content (for mutable revisions)
          vim.api.nvim_win_set_buf(original_win, original_info.bufnr)
          virtual_file.refresh_buffer(original_info.bufnr)
        else
          -- Buffer doesn't exist, create it with :edit!
          vim.api.nvim_set_current_win(original_win)
          vim.cmd("edit! " .. vim.fn.fnameescape(original_info.target))
          original_info.bufnr = vim.api.nvim_get_current_buf()
        end
      else
        -- New real file: create and load buffer
        local bufnr = vim.fn.bufadd(original_info.target)
        vim.fn.bufload(bufnr)
        original_info.bufnr = bufnr
        vim.api.nvim_win_set_buf(original_win, original_info.bufnr)
      end
    else
      -- Existing buffer: verify it's still valid (might have been deleted by rapid updates)
      if vim.api.nvim_buf_is_valid(original_info.bufnr) then
        vim.api.nvim_win_set_buf(original_win, original_info.bufnr)
        -- For real files, reload from disk in case it changed
        if not original_is_virtual then
          -- Use checktime instead of edit! to avoid triggering autocmds
          -- that can cause treesitter yield errors in scheduled callbacks
          vim.api.nvim_buf_call(original_info.bufnr, function()
            vim.cmd("checktime")
          end)
        end
      else
        -- Buffer was deleted, need to recreate
        if original_is_virtual then
          vim.api.nvim_set_current_win(original_win)
          vim.cmd("edit! " .. vim.fn.fnameescape(original_info.target))
          original_info.bufnr = vim.api.nvim_get_current_buf()
        else
          local bufnr = vim.fn.bufadd(original_info.target)
          vim.fn.bufload(bufnr)
          original_info.bufnr = bufnr
          vim.api.nvim_win_set_buf(original_win, original_info.bufnr)
        end
      end
    end
  end

  if vim.api.nvim_win_is_valid(modified_win) then
    if modified_info.needs_edit then
      if modified_is_virtual then
        -- For virtual files with mutable revisions (:0, :1, :2, :3)
        -- Check if buffer already exists and just needs content refresh
        if modified_info.bufnr and vim.api.nvim_buf_is_valid(modified_info.bufnr) then
          -- Buffer exists, just refresh its content (for mutable revisions)
          vim.api.nvim_win_set_buf(modified_win, modified_info.bufnr)
          virtual_file.refresh_buffer(modified_info.bufnr)
        else
          -- Buffer doesn't exist, create it with :edit!
          vim.api.nvim_set_current_win(modified_win)
          vim.cmd("edit! " .. vim.fn.fnameescape(modified_info.target))
          modified_info.bufnr = vim.api.nvim_get_current_buf()
        end
      else
        -- New real file: create and load buffer
        local bufnr = vim.fn.bufadd(modified_info.target)
        vim.fn.bufload(bufnr)
        modified_info.bufnr = bufnr
        vim.api.nvim_win_set_buf(modified_win, modified_info.bufnr)
      end
    else
      -- Existing buffer: verify it's still valid (might have been deleted by rapid updates)
      if vim.api.nvim_buf_is_valid(modified_info.bufnr) then
        vim.api.nvim_win_set_buf(modified_win, modified_info.bufnr)
        -- For real files, reload from disk in case it changed
        if not modified_is_virtual then
          -- Use checktime instead of edit! to avoid triggering autocmds
          -- that can cause treesitter yield errors in scheduled callbacks
          vim.api.nvim_buf_call(modified_info.bufnr, function()
            vim.cmd("checktime")
          end)
        end
      else
        -- Buffer was deleted, need to recreate
        if modified_is_virtual then
          vim.api.nvim_set_current_win(modified_win)
          vim.cmd("edit! " .. vim.fn.fnameescape(modified_info.target))
          modified_info.bufnr = vim.api.nvim_get_current_buf()
        else
          local bufnr = vim.fn.bufadd(modified_info.target)
          vim.fn.bufload(bufnr)
          modified_info.bufnr = bufnr
          vim.api.nvim_win_set_buf(modified_win, modified_info.bufnr)
        end
      end
    end
  end

  -- Update lifecycle session metadata
  lifecycle.update_paths(tabpage, session_config.original_path, session_config.modified_path)

  -- Delete old virtual buffers if they were virtual AND are not reused in either new window
  if lifecycle.is_original_virtual(tabpage) and old_original_buf ~= original_info.bufnr and old_original_buf ~= modified_info.bufnr then
    pcall(vim.api.nvim_buf_delete, old_original_buf, { force = true })
  end

  if lifecycle.is_modified_virtual(tabpage) and old_modified_buf ~= modified_info.bufnr and old_modified_buf ~= original_info.bufnr then
    pcall(vim.api.nvim_buf_delete, old_modified_buf, { force = true })
  end

  -- Update session with new buffer/window IDs
  -- Note: We need to update lifecycle to support this, or recreate session
  -- For now, we'll update the stored diff result and metadata

  -- If no virtual files need loading, render immediately
  if not autocmd_group then
    -- Real files or reused virtual files: Defer until :edit completes
    vim.schedule(render_everything)
  end

  return true
end

return M
