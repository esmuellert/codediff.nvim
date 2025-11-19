-- Diff view creation and window management
local M = {}

local core = require('vscode-diff.render.core')
local lifecycle = require('vscode-diff.render.lifecycle')
local semantic = require('vscode-diff.render.semantic_tokens')
local virtual_file = require('vscode-diff.virtual_file')
local auto_refresh = require('vscode-diff.auto_refresh')
local config = require('vscode-diff.config')
local diff_module = require('vscode-diff.diff')

-- Helper: Check if revision is virtual (commit hash or STAGED)
-- Virtual: "STAGED" or commit hash | Real: nil or "WORKING"
local function is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

-- Prepare buffer information for loading
-- Returns: { bufnr = number?, target = string?, needs_edit = boolean }
-- - If buffer already exists: { bufnr = 123, target = nil, needs_edit = false }
-- - If needs :edit: { bufnr = nil, target = "path or url", needs_edit = true }
local function prepare_buffer(is_virtual, git_root, revision, path)
  if is_virtual then
    -- Virtual file: generate URL, need to :edit it
    local virtual_url = virtual_file.create_url(git_root, revision, path)
    return {
      bufnr = nil,
      target = virtual_url,
      needs_edit = true,
    }
  else
    -- Real file: check if already loaded
    local existing_buf = vim.fn.bufnr(path)
    if existing_buf ~= -1 then
      -- Buffer already exists, reuse it
      return {
        bufnr = existing_buf,
        target = nil,
        needs_edit = false,
      }
    else
      -- Buffer doesn't exist, need to :edit it
      return {
        bufnr = nil,
        target = path,
        needs_edit = true,
      }
    end
  end
end

---@class SessionConfig
---@field mode "standalone"|"explorer"
---@field git_root string?
---@field original_path string
---@field modified_path string
---@field original_revision string?
---@field modified_revision string?
---@field explorer_data table? For explorer mode: { status_result }

-- Common logic: Compute diff and render highlights
-- @param auto_scroll_to_first_hunk boolean: Whether to auto-scroll to first change (default true)
local function compute_and_render(original_buf, modified_buf, original_lines, modified_lines, original_is_virtual, modified_is_virtual, original_win, modified_win, auto_scroll_to_first_hunk)
  -- Compute diff
  local diff_options = {
    max_computation_time_ms = config.options.diff.max_computation_time_ms,
  }
  local lines_diff = diff_module.compute_diff(original_lines, modified_lines, diff_options)
  if not lines_diff then
    vim.notify("Failed to compute diff", vim.log.levels.ERROR)
    return nil
  end

  -- Render diff highlights
  core.render_diff(original_buf, modified_buf, original_lines, modified_lines, lines_diff)

  -- Apply semantic tokens for virtual buffers
  if original_is_virtual then
    semantic.apply_semantic_tokens(original_buf, modified_buf)
  end
  if modified_is_virtual then
    semantic.apply_semantic_tokens(modified_buf, original_buf)
  end

  -- Setup scrollbind synchronization (only if windows provided)
  if original_win and modified_win then
    -- Save cursor position if we need to preserve it (on update)
    local saved_cursor = nil
    if not auto_scroll_to_first_hunk then
      saved_cursor = vim.api.nvim_win_get_cursor(modified_win)
    end
    
    -- Step 1: Cancel previous scrollbind
    vim.wo[original_win].scrollbind = false
    vim.wo[modified_win].scrollbind = false

    -- Step 2: ATOMIC - Reset both to line 1 AND re-enable scrollbind together
    -- This ensures scrollbind is established with proper baseline for filler lines
    vim.api.nvim_win_set_cursor(original_win, {1, 0})
    vim.api.nvim_win_set_cursor(modified_win, {1, 0})
    vim.wo[original_win].scrollbind = true
    vim.wo[modified_win].scrollbind = true
    
    -- Step 3a: On create, scroll to first change
    if auto_scroll_to_first_hunk and #lines_diff.changes > 0 then
      local first_change = lines_diff.changes[1]
      local target_line = first_change.original.start_line

      pcall(vim.api.nvim_win_set_cursor, original_win, {target_line, 0})
      pcall(vim.api.nvim_win_set_cursor, modified_win, {target_line, 0})

      if vim.api.nvim_win_is_valid(modified_win) then
        vim.api.nvim_set_current_win(modified_win)
        vim.cmd("normal! zz")
      end
    -- Step 3b: On update, restore saved cursor position
    elseif saved_cursor then
      pcall(vim.api.nvim_win_set_cursor, modified_win, saved_cursor)
      -- Sync original window to same line (scrollbind will handle column)
      pcall(vim.api.nvim_win_set_cursor, original_win, {saved_cursor[1], 0})
    end
  end

  return lines_diff
end

-- Common logic: Setup auto-refresh for real file buffers
local function setup_auto_refresh(original_buf, modified_buf, original_is_virtual, modified_is_virtual)
  if not original_is_virtual then
    auto_refresh.enable(original_buf)
  end

  if not modified_is_virtual then
    auto_refresh.enable(modified_buf)
  end
end

---@param session_config SessionConfig Session configuration
---@param filetype? string Optional filetype for syntax highlighting
---@return table|nil Result containing diff metadata, or nil if deferred
function M.create(session_config, filetype)
  -- Create new tab (both modes create a tab)
  vim.cmd("tabnew")

  local tabpage = vim.api.nvim_get_current_tabpage()

  -- For explorer mode with empty paths, create empty panes and skip buffer setup
  local is_explorer_placeholder = session_config.mode == "explorer" and 
                                   (session_config.original_path == "" or session_config.original_path == nil)

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

    original_info = prepare_buffer(
      original_is_virtual,
      session_config.git_root,
      session_config.original_revision,
      session_config.original_path
    )
    modified_info = prepare_buffer(
      modified_is_virtual,
      session_config.git_root,
      session_config.modified_revision,
      session_config.modified_path
    )

    initial_buf = vim.api.nvim_get_current_buf()
    original_win = vim.api.nvim_get_current_win()

    -- Load original buffer
    if original_info.needs_edit then
      vim.cmd("edit " .. vim.fn.fnameescape(original_info.target))
      original_info.bufnr = vim.api.nvim_get_current_buf()
    else
      vim.api.nvim_win_set_buf(original_win, original_info.bufnr)
    end

    vim.cmd("vsplit")
    modified_win = vim.api.nvim_get_current_win()

    -- Load modified buffer
    if modified_info.needs_edit then
      vim.cmd("edit " .. vim.fn.fnameescape(modified_info.target))
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
  local win_opts = {
    number = true,
    relativenumber = false,
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
      "",  -- Empty paths indicate placeholder
      "",
      nil,
      nil,
      original_info.bufnr,
      modified_info.bufnr,
      original_win,
      modified_win,
      {}  -- Empty diff result - will be updated on first file selection
    )
  else
    -- Normal mode: Full rendering
    local has_virtual_buffer = is_virtual_revision(session_config.original_revision) or 
                                is_virtual_revision(session_config.modified_revision)
    local original_is_virtual = is_virtual_revision(session_config.original_revision)
    local modified_is_virtual = is_virtual_revision(session_config.modified_revision)
    
    -- Set up rendering after buffers are ready
    local render_everything = function()
      -- Always read from buffers (single source of truth)
      local original_lines = vim.api.nvim_buf_get_lines(original_info.bufnr, 0, -1, false)
      local modified_lines = vim.api.nvim_buf_get_lines(modified_info.bufnr, 0, -1, false)
      
      local lines_diff = compute_and_render(
        original_info.bufnr, modified_info.bufnr,
        original_lines, modified_lines,
        original_is_virtual, modified_is_virtual,
        original_win, modified_win,
        true  -- auto_scroll_to_first_hunk = true on create
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

        -- Setup auto-sync on file switch (after session is complete!)
        lifecycle.setup_auto_sync_on_file_switch(tabpage, original_is_virtual, modified_is_virtual)
      end
    end

    -- Choose timing based on buffer types
    if has_virtual_buffer then
    -- Virtual file(s): Wait for BufReadCmd to load content
    -- Track which virtual buffers have loaded
    local loaded_buffers = {}
    local group = vim.api.nvim_create_augroup('VscodeDiffVirtualFileHighlight_' .. tabpage, { clear = true })

    vim.api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'VscodeDiffVirtualFileLoaded',
      callback = function(event)
        if not event.data or not event.data.buf then return end

        local loaded_buf = event.data.buf

        -- Check if this is one of our virtual buffers
        if (original_is_virtual and loaded_buf == original_info.bufnr) or
           (modified_is_virtual and loaded_buf == modified_info.bufnr) then
          loaded_buffers[loaded_buf] = true

          -- Check if all virtual buffers are loaded
          local all_loaded = true
          if original_is_virtual and not loaded_buffers[original_info.bufnr] then
            all_loaded = false
          end
          if modified_is_virtual and not loaded_buffers[modified_info.bufnr] then
            all_loaded = false
          end

          -- Render once all virtual buffers are ready
          if all_loaded then
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
    -- Calculate explorer width: 20% of terminal width or 40 columns, whichever is smaller (matches neo-tree default)
    local total_width = vim.o.columns
    local explorer_width = math.min(40, math.floor(total_width * 0.2))
    
    -- Create explorer in left sidebar (explorer manages its own lifecycle and callbacks)
    local explorer = require('vscode-diff.render.explorer')
    local status_result = session_config.explorer_data.status_result
    
    explorer.create(status_result, session_config.git_root, tabpage, explorer_width)
    
    -- After explorer is created, adjust diff window widths to be equal
    local remaining_width = total_width - explorer_width
    local diff_width = math.floor(remaining_width / 2)
    
    vim.api.nvim_win_set_width(original_win, diff_width)
    vim.api.nvim_win_set_width(modified_win, diff_width)
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

  -- Determine if new buffers are virtual
  local original_is_virtual = is_virtual_revision(session_config.original_revision)
  local modified_is_virtual = is_virtual_revision(session_config.modified_revision)

  -- Prepare new buffer information
  local original_info = prepare_buffer(
    original_is_virtual,
    session_config.git_root,
    session_config.original_revision,
    session_config.original_path
  )
  local modified_info = prepare_buffer(
    modified_is_virtual,
    session_config.git_root,
    session_config.modified_revision,
    session_config.modified_path
  )

  -- CRITICAL: If the buffer we want to load already exists and is displayed in OTHER diff window,
  -- we need to replace that window's buffer FIRST before :edit, otherwise :edit will reuse it
  -- This fixes the bug where same file in staged+unstaged shows same buffer in both windows
  
  local buffers_to_delete = {}
  
  -- Check if original window's target buffer is currently in modified window
  if original_info.needs_edit then
    local existing = vim.fn.bufnr(original_info.target)
    if existing ~= -1 and existing == old_modified_buf then
      -- Replace modified window with empty buffer first
      vim.api.nvim_set_current_win(modified_win)
      vim.cmd("enew")
      table.insert(buffers_to_delete, old_modified_buf)
      old_modified_buf = vim.api.nvim_get_current_buf()  -- Update to new empty buffer
    end
  end
  
  -- Check if modified window's target buffer is currently in original window
  if modified_info.needs_edit then
    local existing = vim.fn.bufnr(modified_info.target)
    if existing ~= -1 and existing == old_original_buf then
      -- Replace original window with empty buffer first
      vim.api.nvim_set_current_win(original_win)
      vim.cmd("enew")
      table.insert(buffers_to_delete, old_original_buf)
      old_original_buf = vim.api.nvim_get_current_buf()  -- Update to new empty buffer
    end
  end

  -- Now load buffers - :edit will create fresh buffers since we replaced conflicting ones
  vim.api.nvim_set_current_win(original_win)
  if original_info.needs_edit then
    vim.cmd("edit " .. vim.fn.fnameescape(original_info.target))
    original_info.bufnr = vim.api.nvim_get_current_buf()
  else
    vim.api.nvim_win_set_buf(original_win, original_info.bufnr)
  end

  vim.api.nvim_set_current_win(modified_win)
  if modified_info.needs_edit then
    vim.cmd("edit " .. vim.fn.fnameescape(modified_info.target))
    modified_info.bufnr = vim.api.nvim_get_current_buf()
  else
    vim.api.nvim_win_set_buf(modified_win, modified_info.bufnr)
  end
  
  -- Delete the old buffers we replaced (after windows have new content)
  for _, buf in ipairs(buffers_to_delete) do
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  -- Update lifecycle session metadata
  lifecycle.update_paths(tabpage, session_config.original_path, session_config.modified_path)

  -- Delete old virtual buffers if they were virtual
  if lifecycle.is_original_virtual(tabpage) and old_original_buf ~= original_info.bufnr then
    pcall(vim.api.nvim_buf_delete, old_original_buf, { force = true })
  end
  if lifecycle.is_modified_virtual(tabpage) and old_modified_buf ~= modified_info.bufnr then
    pcall(vim.api.nvim_buf_delete, old_modified_buf, { force = true })
  end

  -- Update session with new buffer/window IDs
  -- Note: We need to update lifecycle to support this, or recreate session
  -- For now, we'll update the stored diff result and metadata

  -- Determine if we need to wait for virtual file content
  local has_virtual_buffer = original_is_virtual or modified_is_virtual

  local render_everything = function()
    -- Always read from buffers (single source of truth)
    local original_lines = vim.api.nvim_buf_get_lines(original_info.bufnr, 0, -1, false)
    local modified_lines = vim.api.nvim_buf_get_lines(modified_info.bufnr, 0, -1, false)
    
    -- Compute and render (scrollbind will be handled inside)
    -- Use the provided auto_scroll parameter, default to false if not specified
    local should_auto_scroll = auto_scroll_to_first_hunk == true
    local lines_diff = compute_and_render(
      original_info.bufnr, modified_info.bufnr,
      original_lines, modified_lines,
      original_is_virtual, modified_is_virtual,
      original_win, modified_win,
      should_auto_scroll
    )

    if lines_diff then
      -- Update lifecycle session with all new state
      lifecycle.update_buffers(tabpage, original_info.bufnr, modified_info.bufnr)
      lifecycle.update_git_root(tabpage, session_config.git_root)
      lifecycle.update_revisions(tabpage, session_config.original_revision, session_config.modified_revision)
      lifecycle.update_diff_result(tabpage, lines_diff)
      lifecycle.update_changedtick(
        tabpage,
        vim.api.nvim_buf_get_changedtick(original_info.bufnr),
        vim.api.nvim_buf_get_changedtick(modified_info.bufnr)
      )

      -- Re-enable auto-refresh for real file buffers
      setup_auto_refresh(original_info.bufnr, modified_info.bufnr, original_is_virtual, modified_is_virtual)
    end
  end

  -- Choose timing based on buffer types
  if has_virtual_buffer then
    -- Virtual file(s): Wait for BufReadCmd to load content
    -- Track which virtual buffers have loaded
    local loaded_buffers = {}
    local group = vim.api.nvim_create_augroup('VscodeDiffVirtualFileUpdate_' .. tabpage, { clear = true })

    vim.api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'VscodeDiffVirtualFileLoaded',
      callback = function(event)
        if not event.data or not event.data.buf then return end

        local loaded_buf = event.data.buf

        -- Check if this is one of our virtual buffers
        if (original_is_virtual and loaded_buf == original_info.bufnr) or
           (modified_is_virtual and loaded_buf == modified_info.bufnr) then
          loaded_buffers[loaded_buf] = true

          -- Check if all virtual buffers are loaded
          local all_loaded = true
          if original_is_virtual and not loaded_buffers[original_info.bufnr] then
            all_loaded = false
          end
          if modified_is_virtual and not loaded_buffers[modified_info.bufnr] then
            all_loaded = false
          end

          -- Render once all virtual buffers are ready
          if all_loaded then
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

  return true
end

return M
