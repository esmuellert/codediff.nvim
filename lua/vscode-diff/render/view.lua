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
    -- Virtual file: generate URL
    local virtual_url = virtual_file.create_url(git_root, revision, path)
    -- Check if buffer already exists
    local existing_buf = vim.fn.bufnr(virtual_url)
    
    -- For :0 (staged index), always force reload because index can change
    -- when user runs git add/reset. For commits (immutable), we can cache.
    local is_mutable_revision = revision == ":0" or revision == ":1" or revision == ":2" or revision == ":3"
    
    if existing_buf ~= -1 and not is_mutable_revision then
       -- Buffer exists for immutable revision, reuse it
       return {
         bufnr = existing_buf,
         target = virtual_url,
         needs_edit = false
       }
    else
       -- Either buffer doesn't exist, or it's a mutable revision that needs refresh
       -- Don't delete here - let the :edit! handle it (will trigger BufReadCmd)
       return {
         bufnr = existing_buf ~= -1 and existing_buf or nil,
         target = virtual_url,
         needs_edit = true,
       }
    end
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
  if original_win and modified_win and vim.api.nvim_win_is_valid(original_win) and vim.api.nvim_win_is_valid(modified_win) then
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
    
    -- Re-apply critical window options that might have been reset
    vim.wo[original_win].wrap = false
    vim.wo[modified_win].wrap = false
    
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

-- Centralized keymap setup for all diff view keymaps
-- This function sets up ALL keymaps in one place for better maintainability
local function setup_all_keymaps(tabpage, original_bufnr, modified_bufnr, is_explorer_mode)
  local keymaps = config.options.keymaps.view

  -- Helper: Navigate to next hunk
  local function navigate_next_hunk()
    local session = lifecycle.get_session(tabpage)
    if not session or not session.stored_diff_result then return end
    local diff_result = session.stored_diff_result
    if #diff_result.changes == 0 then return end

    local current_buf = vim.api.nvim_get_current_buf()
    local is_original = current_buf == original_bufnr
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]

    -- Find next hunk after current line
    for i, mapping in ipairs(diff_result.changes) do
      local target_line = is_original and mapping.original.start_line or mapping.modified.start_line
      if target_line > current_line then
        pcall(vim.api.nvim_win_set_cursor, 0, {target_line, 0})
        vim.api.nvim_echo({{string.format('Hunk %d of %d', i, #diff_result.changes), 'None'}}, false, {})
        return
      end
    end

    -- Wrap around to first hunk
    local first_hunk = diff_result.changes[1]
    local target_line = is_original and first_hunk.original.start_line or first_hunk.modified.start_line
    pcall(vim.api.nvim_win_set_cursor, 0, {target_line, 0})
    vim.api.nvim_echo({{string.format('Hunk 1 of %d', #diff_result.changes), 'None'}}, false, {})
  end

  -- Helper: Navigate to previous hunk
  local function navigate_prev_hunk()
    local session = lifecycle.get_session(tabpage)
    if not session or not session.stored_diff_result then return end
    local diff_result = session.stored_diff_result
    if #diff_result.changes == 0 then return end

    local current_buf = vim.api.nvim_get_current_buf()
    local is_original = current_buf == original_bufnr
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]

    -- Find previous hunk before current line (search backwards)
    for i = #diff_result.changes, 1, -1 do
      local mapping = diff_result.changes[i]
      local target_line = is_original and mapping.original.start_line or mapping.modified.start_line
      if target_line < current_line then
        pcall(vim.api.nvim_win_set_cursor, 0, {target_line, 0})
        vim.api.nvim_echo({{string.format('Hunk %d of %d', i, #diff_result.changes), 'None'}}, false, {})
        return
      end
    end

    -- Wrap around to last hunk
    local last_hunk = diff_result.changes[#diff_result.changes]
    local target_line = is_original and last_hunk.original.start_line or last_hunk.modified.start_line
    pcall(vim.api.nvim_win_set_cursor, 0, {target_line, 0})
    vim.api.nvim_echo({{string.format('Hunk %d of %d', #diff_result.changes, #diff_result.changes), 'None'}}, false, {})
  end

  -- Helper: Navigate to next file (explorer mode only)
  local function navigate_next_file()
    local explorer_obj = lifecycle.get_explorer(tabpage)
    if not explorer_obj then
      vim.notify("No explorer found for this tab", vim.log.levels.WARN)
      return
    end
    local explorer = require('vscode-diff.render.explorer')
    explorer.navigate_next(explorer_obj)
  end

  -- Helper: Navigate to previous file (explorer mode only)
  local function navigate_prev_file()
    local explorer_obj = lifecycle.get_explorer(tabpage)
    if not explorer_obj then
      vim.notify("No explorer found for this tab", vim.log.levels.WARN)
      return
    end
    local explorer = require('vscode-diff.render.explorer')
    explorer.navigate_prev(explorer_obj)
  end

  -- Helper: Quit diff view
  local function quit_diff()
    vim.cmd('tabclose')
  end

  -- Helper: Toggle explorer visibility (explorer mode only)
  local function toggle_explorer()
    local explorer_obj = lifecycle.get_explorer(tabpage)
    if not explorer_obj then
      vim.notify("No explorer found for this tab", vim.log.levels.WARN)
      return
    end
    local explorer = require('vscode-diff.render.explorer')
    explorer.toggle_visibility(explorer_obj)
  end

  -- Helper: Find hunk at cursor position
  -- Returns the hunk and its index, or nil if cursor is not in a hunk
  local function find_hunk_at_cursor()
    local session = lifecycle.get_session(tabpage)
    if not session or not session.stored_diff_result then return nil, nil end
    local diff_result = session.stored_diff_result
    if #diff_result.changes == 0 then return nil, nil end

    local current_buf = vim.api.nvim_get_current_buf()
    local is_original = current_buf == original_bufnr
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]

    for i, mapping in ipairs(diff_result.changes) do
      local start_line = is_original and mapping.original.start_line or mapping.modified.start_line
      local end_line = is_original and mapping.original.end_line or mapping.modified.end_line
      -- Check if cursor is within this hunk (end_line is exclusive)
      if current_line >= start_line and current_line < end_line then
        return mapping, i
      end
      -- Also match if it's a deletion (empty range) and cursor is at start
      if start_line == end_line and current_line == start_line then
        return mapping, i
      end
    end
    return nil, nil
  end

  -- Helper: Diff get - obtain change from other buffer to current buffer
  local function diff_get()
    local session = lifecycle.get_session(tabpage)
    if not session then return end

    local current_buf = vim.api.nvim_get_current_buf()
    local is_original = current_buf == original_bufnr
    local target_buf = current_buf
    local source_buf = is_original and modified_bufnr or original_bufnr

    -- Check if target buffer is modifiable
    if not vim.bo[target_buf].modifiable then
      vim.notify("Buffer is not modifiable", vim.log.levels.WARN)
      return
    end

    local hunk, hunk_idx = find_hunk_at_cursor()
    if not hunk then
      vim.notify("No hunk at cursor position", vim.log.levels.WARN)
      return
    end

    -- Get source and target ranges
    local source_range = is_original and hunk.modified or hunk.original
    local target_range = is_original and hunk.original or hunk.modified

    -- Get lines from source buffer
    local source_lines = vim.api.nvim_buf_get_lines(
      source_buf,
      source_range.start_line - 1,
      source_range.end_line - 1,
      false
    )

    -- Replace lines in target buffer
    vim.api.nvim_buf_set_lines(
      target_buf,
      target_range.start_line - 1,
      target_range.end_line - 1,
      false,
      source_lines
    )

    -- Trigger diff refresh to update highlights
    auto_refresh.trigger(target_buf)

    vim.api.nvim_echo({{string.format('Obtained hunk %d', hunk_idx), 'None'}}, false, {})
  end

  -- Helper: Diff put - put change from current buffer to other buffer
  local function diff_put()
    local session = lifecycle.get_session(tabpage)
    if not session then return end

    local current_buf = vim.api.nvim_get_current_buf()
    local is_original = current_buf == original_bufnr
    local source_buf = current_buf
    local target_buf = is_original and modified_bufnr or original_bufnr

    -- Check if target buffer is modifiable
    if not vim.bo[target_buf].modifiable then
      vim.notify("Target buffer is not modifiable", vim.log.levels.WARN)
      return
    end

    local hunk, hunk_idx = find_hunk_at_cursor()
    if not hunk then
      vim.notify("No hunk at cursor position", vim.log.levels.WARN)
      return
    end

    -- Get source and target ranges
    local source_range = is_original and hunk.original or hunk.modified
    local target_range = is_original and hunk.modified or hunk.original

    -- Get lines from source buffer
    local source_lines = vim.api.nvim_buf_get_lines(
      source_buf,
      source_range.start_line - 1,
      source_range.end_line - 1,
      false
    )

    -- Replace lines in target buffer
    vim.api.nvim_buf_set_lines(
      target_buf,
      target_range.start_line - 1,
      target_range.end_line - 1,
      false,
      source_lines
    )

    -- Trigger diff refresh to update highlights
    auto_refresh.trigger(target_buf)

    vim.api.nvim_echo({{string.format('Put hunk %d', hunk_idx), 'None'}}, false, {})
  end

  -- ========================================================================
  -- Bind all keymaps using unified API (one place for all keymaps!)
  -- ========================================================================

  -- Quit keymap (q)
  if keymaps.quit then
    lifecycle.set_tab_keymap(tabpage, 'n', keymaps.quit, quit_diff, { desc = 'Close diff view' })
  end

  -- Hunk navigation (]c, [c)
  if keymaps.next_hunk then
    lifecycle.set_tab_keymap(tabpage, 'n', keymaps.next_hunk, navigate_next_hunk, { desc = 'Next hunk' })
  end
  if keymaps.prev_hunk then
    lifecycle.set_tab_keymap(tabpage, 'n', keymaps.prev_hunk, navigate_prev_hunk, { desc = 'Previous hunk' })
  end

  -- Explorer toggle (e) - only in explorer mode
  if is_explorer_mode and keymaps.toggle_explorer then
    lifecycle.set_tab_keymap(tabpage, 'n', keymaps.toggle_explorer, toggle_explorer, { desc = 'Toggle explorer visibility' })
  end

  -- File navigation (]f, [f) - only in explorer mode
  if is_explorer_mode then
    if keymaps.next_file then
      lifecycle.set_tab_keymap(tabpage, 'n', keymaps.next_file, navigate_next_file, { desc = 'Next file in explorer' })
    end
    if keymaps.prev_file then
      lifecycle.set_tab_keymap(tabpage, 'n', keymaps.prev_file, navigate_prev_file, { desc = 'Previous file in explorer' })
    end
  end

  -- Diff get/put (do, dp) - like vimdiff
  if keymaps.diff_get then
    lifecycle.set_tab_keymap(tabpage, 'n', keymaps.diff_get, diff_get, { desc = 'Get change from other buffer' })
  end
  if keymaps.diff_put then
    lifecycle.set_tab_keymap(tabpage, 'n', keymaps.diff_put, diff_put, { desc = 'Put change to other buffer' })
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

        -- Setup all keymaps in one place (centralized)
        setup_all_keymaps(tabpage, original_info.bufnr, modified_info.bufnr, false)

        -- Setup auto-sync on file switch (after session is complete!)
        lifecycle.setup_auto_sync_on_file_switch(tabpage, original_is_virtual, modified_is_virtual)
      end
    end

    -- Choose timing based on buffer types
    -- Since we force reload virtual files, we ALWAYS wait for the load event if virtual files exist
    local has_virtual = original_is_virtual or modified_is_virtual

    if has_virtual then
    -- Virtual file(s): Wait for BufReadCmd to load content
    local group = vim.api.nvim_create_augroup('VscodeDiffVirtualFileHighlight_' .. tabpage, { clear = true })

    vim.api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'VscodeDiffVirtualFileLoaded',
      callback = function(event)
        if not event.data or not event.data.buf then return end

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
    
    vim.api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'VscodeDiffVirtualFileLoaded',
      callback = function(event)
        if not event.data or not event.data.buf then return end
        local loaded_buf = event.data.buf
        
        if (original_is_virtual and loaded_buf == original_info.bufnr) or
           (modified_is_virtual and loaded_buf == modified_info.bufnr) then
           
           loaded_buffers[loaded_buf] = true
           
           local ready = true
           if original_is_virtual and not loaded_buffers[original_info.bufnr] then ready = false end
           if modified_is_virtual and not loaded_buffers[modified_info.bufnr] then ready = false end
           
           if ready then
             vim.schedule(render_everything)
             vim.api.nvim_del_augroup_by_id(group)
           end
        end
      end
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
    
    local explorer_obj = explorer.create(status_result, session_config.git_root, tabpage, explorer_width, session_config.original_revision, session_config.modified_revision)
    
    -- Store explorer reference in lifecycle
    lifecycle.set_explorer(tabpage, explorer_obj)
    
    -- Note: Keymaps will be set when first file is selected via update()
    
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
          vim.api.nvim_buf_call(original_info.bufnr, function()
            vim.cmd("silent! edit!")
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
          vim.api.nvim_buf_call(modified_info.bufnr, function()
            vim.cmd("silent! edit!")
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
  if lifecycle.is_original_virtual(tabpage) and 
     old_original_buf ~= original_info.bufnr and 
     old_original_buf ~= modified_info.bufnr then
    pcall(vim.api.nvim_buf_delete, old_original_buf, { force = true })
  end
  
  if lifecycle.is_modified_virtual(tabpage) and 
     old_modified_buf ~= modified_info.bufnr and 
     old_modified_buf ~= original_info.bufnr then
    pcall(vim.api.nvim_buf_delete, old_modified_buf, { force = true })
  end

  -- Update session with new buffer/window IDs
  -- Note: We need to update lifecycle to support this, or recreate session
  -- For now, we'll update the stored diff result and metadata

  -- Determine if we need to wait for virtual file content
  -- Since we force reload virtual files, we always wait for the load event
  -- Use a state table to avoid closure capture issues in autocmd
  local wait_state = {
    original = original_is_virtual and original_info.needs_edit,
    modified = modified_is_virtual and modified_info.needs_edit
  }

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

      -- Setup all keymaps in one place (centralized)
      local is_explorer_mode = session.mode == "explorer"
      setup_all_keymaps(tabpage, original_info.bufnr, modified_info.bufnr, is_explorer_mode)
    end
  end

  -- Choose timing based on buffer types
  if wait_state.original or wait_state.modified then
    -- Virtual file(s): Wait for BufReadCmd to load content
    local group = vim.api.nvim_create_augroup('VscodeDiffVirtualFileUpdate_' .. tabpage, { clear = true })

    vim.api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'VscodeDiffVirtualFileLoaded',
      callback = function(event)
        if not event.data or not event.data.buf then return end

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
          vim.api.nvim_del_augroup_by_id(group)
        end
      end,
    })
  else
    -- Real files or reused virtual files: Defer until :edit completes
    vim.schedule(render_everything)
  end

  return true
end

return M
