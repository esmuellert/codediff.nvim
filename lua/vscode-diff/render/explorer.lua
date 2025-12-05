-- Git status explorer using nui.nvim
local M = {}

local Tree = require("nui.tree")
local NuiLine = require("nui.line")
local Split = require("nui.split")
local config = require("vscode-diff.config")

-- Status symbols and colors
local STATUS_SYMBOLS = {
  M = { symbol = "M", color = "DiagnosticWarn" },
  A = { symbol = "A", color = "DiagnosticOk" },
  D = { symbol = "D", color = "DiagnosticError" },
  ["??"] = { symbol = "??", color = "DiagnosticInfo" },
  ["!"] = { symbol = "!", color = "DiagnosticError" },  -- Merge conflict
}

-- File icons (basic fallback)
local function get_file_icon(path)
  local has_devicons, devicons = pcall(require, "nvim-web-devicons")
  if has_devicons then
    local icon, color = devicons.get_icon(path, nil, { default = true })
    return icon or "", color
  end
  return "", nil
end

-- Create tree nodes for file list
local function create_file_nodes(files, git_root, group)
  local nodes = {}
  for _, file in ipairs(files) do
    local icon, icon_color = get_file_icon(file.path)
    local status_info = STATUS_SYMBOLS[file.status] or { symbol = file.status, color = "Normal" }

    nodes[#nodes + 1] = Tree.Node({
      text = file.path,
      data = {
        path = file.path,
        status = file.status,
        old_path = file.old_path,  -- For renames: original path before rename
        icon = icon,
        icon_color = icon_color,
        status_symbol = status_info.symbol,
        status_color = status_info.color,
        git_root = git_root,
        group = group,
      }
    })
  end
  return nodes
end

-- Create explorer tree structure
local function create_tree_data(status_result, git_root, base_revision)
  local unstaged_nodes = create_file_nodes(status_result.unstaged, git_root, "unstaged")
  local staged_nodes = create_file_nodes(status_result.staged, git_root, "staged")
  local conflict_nodes = status_result.conflicts and create_file_nodes(status_result.conflicts, git_root, "conflicts") or {}

  if base_revision then
    -- Revision mode: single group showing all changes
    return {
      Tree.Node({
        text = string.format("Changes (%d)", #status_result.unstaged),
        data = { type = "group", name = "unstaged" },
      }, unstaged_nodes),
    }
  else
    -- Status mode: separate conflicts/staged/unstaged groups
    local tree_nodes = {}
    
    -- Conflicts first (most important)
    if #conflict_nodes > 0 then
      table.insert(tree_nodes, Tree.Node({
        text = string.format("Merge Changes (%d)", #conflict_nodes),
        data = { type = "group", name = "conflicts" },
      }, conflict_nodes))
    end
    
    -- Unstaged changes
    table.insert(tree_nodes, Tree.Node({
      text = string.format("Changes (%d)", #status_result.unstaged),
      data = { type = "group", name = "unstaged" },
    }, unstaged_nodes))
    
    -- Staged changes
    table.insert(tree_nodes, Tree.Node({
      text = string.format("Staged Changes (%d)", #status_result.staged),
      data = { type = "group", name = "staged" },
    }, staged_nodes))
    
    return tree_nodes
  end
end

-- Render tree node
local function prepare_node(node, max_width, selected_path, selected_group)
  local line = NuiLine()
  local data = node.data or {}

  if data.type == "group" then
    -- Group header
    local icon = node:is_expanded() and "" or ""
    line:append(icon .. " ", "Directory")
    line:append(node.text, "Directory")
  else
    -- Match both path AND group to handle files in both staged and unstaged
    local is_selected = data.path and data.path == selected_path and data.group == selected_group
    local function get_hl(default)
      return is_selected and "CodeDiffExplorerSelected" or (default or "Normal")
    end

    -- File entry - VSCode style: filename (bold) + directory (dimmed) + status (right-aligned)
    local indent = string.rep("  ", node:get_depth() - 1)
    line:append(indent, get_hl("Normal"))
    
    local icon_part = ""
    if data.icon then
      icon_part = data.icon .. " "
      line:append(icon_part, get_hl(data.icon_color))
    end
    
    -- Status symbol at the end (e.g., "M", "D", "??")
    local status_symbol = data.status_symbol or ""
    
    -- Split path into filename and directory
    local full_path = data.path or node.text
    local filename = full_path:match("([^/]+)$") or full_path
    local directory = full_path:sub(1, -(#filename + 1))  -- Remove filename, keep trailing /
    
    -- Calculate how much width we've used and reserve for status
    local used_width = vim.fn.strdisplaywidth(indent) + vim.fn.strdisplaywidth(icon_part)
    local status_reserve = vim.fn.strdisplaywidth(status_symbol) + 2  -- 2 spaces padding before status
    local available_for_content = max_width - used_width - status_reserve
    
    -- VSCode shows: filename + directory (dimmed), truncate directory if needed
    local filename_len = vim.fn.strdisplaywidth(filename)
    local directory_len = vim.fn.strdisplaywidth(directory)
    local space_len = (directory_len > 0) and 1 or 0  -- Account for space between filename and directory
    
    if filename_len + space_len + directory_len > available_for_content then
      -- Prioritize showing full filename, truncate directory from end (right)
      local available_for_dir = available_for_content - filename_len - space_len
      if available_for_dir > 3 then
        -- Show truncated directory (from the start, hide the end)
        local ellipsis = "..."
        local chars_to_keep = available_for_dir - vim.fn.strdisplaywidth(ellipsis)
        
        -- Truncate directory by display width, not byte index
        local byte_pos = 0
        local accumulated_width = 0
        for char in vim.gsplit(directory, "") do
          local char_width = vim.fn.strdisplaywidth(char)
          if accumulated_width + char_width > chars_to_keep then break end
          accumulated_width = accumulated_width + char_width
          byte_pos = byte_pos + #char
        end
        directory = directory:sub(1, byte_pos) .. ellipsis
      else
        -- Not enough space for directory, just show filename
        directory = ""
        space_len = 0
      end
    end
    
    -- Append filename (normal weight) and directory (dimmed with smaller font)
    line:append(filename, get_hl("Normal"))
    if #directory > 0 then
      line:append(" ", get_hl("Normal"))
      line:append(directory, get_hl("ExplorerDirectorySmall"))  -- Smaller dimmed style
    end
    
    -- Add padding to push status symbol to the right edge
    local content_len = vim.fn.strdisplaywidth(filename) + space_len + vim.fn.strdisplaywidth(directory)
    local padding_needed = available_for_content - content_len + 2
    if padding_needed > 0 then
      line:append(string.rep(" ", padding_needed), get_hl("Normal"))
    end
    line:append(status_symbol, get_hl(data.status_color))
  end

  return line
end

-- Create and show explorer
function M.create(status_result, git_root, tabpage, width, base_revision, target_revision)
  -- Use provided width or default to 40 columns (same as neo-tree)
  local explorer_width = width or 40
  
  -- Create split window for explorer
  local split = Split({
    relative = "editor",
    position = "left",
    size = explorer_width,
    buf_options = {
      modifiable = false,
      readonly = true,
      filetype = "vscode-diff-explorer",
    },
    win_options = {
      number = false,
      relativenumber = false,
      cursorline = true,
      wrap = false,
      signcolumn = "no",
      foldcolumn = "0",
    },
  })

  -- Mount split first to get bufnr
  split:mount()

  -- Track selected path and group for highlighting
  local selected_path = nil
  local selected_group = nil

  -- Create tree with buffer number
  local tree_data = create_tree_data(status_result, git_root, base_revision)
  local tree = Tree({
    bufnr = split.bufnr,
    nodes = tree_data,
    prepare_node = function(node)
      return prepare_node(node, explorer_width, selected_path, selected_group)
    end,
  })

  -- Expand all groups by default before first render
  for _, node in ipairs(tree_data) do
    if node.data and node.data.type == "group" then
      node:expand()
    end
  end

  -- Render tree
  tree:render()

  -- Create explorer object early so we can reference it in keymaps
  local explorer = {
    split = split,
    tree = tree,
    bufnr = split.bufnr,
    winid = split.winid,
    git_root = git_root,
    base_revision = base_revision,
    target_revision = target_revision,
    status_result = status_result, -- Store initial status result
    on_file_select = nil,  -- Will be set below
    current_file_path = nil,  -- Track currently selected file
    current_file_group = nil, -- Track currently selected file's group (staged/unstaged)
    is_hidden = false,  -- Track visibility state
  }

  -- File selection callback - manages its own lifecycle
  local function on_file_select(file_data)
    local git = require('vscode-diff.git')
    local view = require('vscode-diff.render.view')
    local lifecycle = require('vscode-diff.render.lifecycle')
    
    local file_path = file_data.path
    local old_path = file_data.old_path  -- For renames: path in original revision
    local abs_path = git_root .. "/" .. file_path
    local group = file_data.group or "unstaged"

    -- Check if this exact diff is already being displayed
    -- Same file can have different diffs (staged vs HEAD, working vs staged)
    local session = lifecycle.get_session(tabpage)
    if session then
      local is_same_file = (session.modified_path == abs_path or 
                           (session.git_root and session.original_path == file_path))
      
      if is_same_file then
        -- Check if it's the same diff comparison
        local is_staged_diff = group == "staged"
        local current_is_staged = session.modified_revision == ":0"
        
        if is_staged_diff == current_is_staged then
          -- Same file AND same diff type, skip update
          return
        end
      end
    end

    if base_revision and target_revision and target_revision ~= "WORKING" then
      -- Two revision mode: Compare base vs target
      vim.schedule(function()
        ---@type SessionConfig
        local session_config = {
          mode = "explorer",
          git_root = git_root,
          original_path = old_path or file_path,
          modified_path = file_path,
          original_revision = base_revision,
          modified_revision = target_revision,
        }
        view.update(tabpage, session_config, true)
      end)
      return
    end

    -- Use base_revision if provided, otherwise default to HEAD
    local target_revision_single = base_revision or "HEAD"
    git.resolve_revision(target_revision_single, git_root, function(err_resolve, commit_hash)
      if err_resolve then
        vim.schedule(function()
          vim.notify(err_resolve, vim.log.levels.ERROR)
        end)
        return
      end

      if base_revision then
        -- Revision mode: Simple comparison of working tree vs base_revision
        vim.schedule(function()
          ---@type SessionConfig
          local session_config = {
            mode = "explorer",
            git_root = git_root,
            original_path = old_path or file_path,
            modified_path = abs_path,
            original_revision = commit_hash,
            modified_revision = nil,
          }
          view.update(tabpage, session_config, true)
        end)
      elseif group == "conflicts" then
        -- Merge conflict: Show incoming (:3:) vs current (:2:), both diffed against base (:1:)
        vim.schedule(function()
          ---@type SessionConfig
          local session_config = {
            mode = "explorer",
            git_root = git_root,
            original_path = file_path,
            modified_path = file_path,
            original_revision = ":3:",  -- Theirs/Incoming (left buffer)
            modified_revision = ":2:",  -- Ours/Current (right buffer)
            conflict = true,
          }
          view.update(tabpage, session_config, true)
        end)
      elseif group == "staged" then
        -- Staged changes: Compare staged (:0) vs HEAD (both virtual)
        -- For renames: old_path in HEAD, new path in staging
        -- No pre-fetching needed, virtual files will load via BufReadCmd
        vim.schedule(function()
          ---@type SessionConfig
          local session_config = {
            mode = "explorer",
            git_root = git_root,
            original_path = old_path or file_path,  -- Use old_path if rename
            modified_path = file_path,              -- New path after rename
            original_revision = commit_hash,
            modified_revision = ":0",
          }
          view.update(tabpage, session_config, true)
        end)
      else
        -- Unstaged changes: Compare working tree vs staged (if exists) or HEAD
        -- Check if file is in staged list
        local is_staged = false
        -- Use current status_result from explorer object
        local current_status = explorer.status_result or status_result
        for _, staged_file in ipairs(current_status.staged) do
          if staged_file.path == file_path then
            is_staged = true
            break
          end
        end

        local original_revision = is_staged and ":0" or commit_hash

        -- No pre-fetching needed, buffers will load content
        vim.schedule(function()
          ---@type SessionConfig
          local session_config = {
            mode = "explorer",
            git_root = git_root,
            original_path = file_path,
            modified_path = abs_path,
            original_revision = original_revision,
            modified_revision = nil,
          }
          view.update(tabpage, session_config, true)
        end)
      end
    end)
  end
  
  -- Wrap on_file_select to track current file and group
  explorer.on_file_select = function(file_data)
    explorer.current_file_path = file_data.path
    explorer.current_file_group = file_data.group
    selected_path = file_data.path
    selected_group = file_data.group
    tree:render()
    on_file_select(file_data)
  end

  -- Keymaps
  local map_options = { noremap = true, silent = true, nowait = true }

  -- Toggle expand/collapse
  if config.options.keymaps.explorer.select then
    vim.keymap.set("n", config.options.keymaps.explorer.select, function()
      local node = tree:get_node()
      if not node then return end
  
      if node.data and node.data.type == "group" then
        -- Toggle group
        if node:is_expanded() then
          node:collapse()
        else
          node:expand()
        end
        tree:render()
      else
        -- File selected
        if node.data then
          explorer.on_file_select(node.data)
        end
      end
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr }))
  end

  -- Double click also works for files
  vim.keymap.set("n", "<2-LeftMouse>", function()
    local node = tree:get_node()
    if not node or not node.data or node.data.type == "group" then return end
    explorer.on_file_select(node.data)
  end, vim.tbl_extend("force", map_options, { buffer = split.bufnr }))

  -- Close explorer (disabled)
  -- vim.keymap.set("n", "q", function()
  --   split:unmount()
  -- end, vim.tbl_extend("force", map_options, { buffer = split.bufnr }))
  
  -- Hover to show full path (K key, like LSP hover)
  local hover_win = nil
  if config.options.keymaps.explorer.hover then
    vim.keymap.set("n", config.options.keymaps.explorer.hover, function()
      -- Close existing hover window
      if hover_win and vim.api.nvim_win_is_valid(hover_win) then
        vim.api.nvim_win_close(hover_win, true)
        hover_win = nil
        return
      end
      
      local node = tree:get_node()
      if not node or not node.data or node.data.type == "group" then return end
      
      local full_path = node.data.path
      local display_text = git_root .. "/" .. full_path
      
      -- Create hover buffer
      local hover_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(hover_buf, 0, -1, false, { display_text })
      vim.bo[hover_buf].modifiable = false
      
      -- Calculate window position (next to cursor)
      local cursor = vim.api.nvim_win_get_cursor(0)
      local row = cursor[1] - 1
      local col = vim.api.nvim_win_get_width(0)
      
      -- Calculate window dimensions with wrapping
      local max_width = 80
      local text_len = #display_text
      local width = math.min(text_len + 2, max_width)
      local height = math.ceil(text_len / (max_width - 2))  -- Account for padding
      
      -- Create floating window with wrap enabled
      hover_win = vim.api.nvim_open_win(hover_buf, false, {
        relative = "win",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
      })
      
      -- Enable wrap in hover window
      vim.wo[hover_win].wrap = true
      
      -- Auto-close on cursor move or buffer leave
      vim.api.nvim_create_autocmd({"CursorMoved", "BufLeave"}, {
        buffer = split.bufnr,
        once = true,
        callback = function()
          if hover_win and vim.api.nvim_win_is_valid(hover_win) then
            vim.api.nvim_win_close(hover_win, true)
            hover_win = nil
          end
        end,
      })
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr }))
  end
  
  -- Refresh explorer (R key)
  if config.options.keymaps.explorer.refresh then
    vim.keymap.set("n", config.options.keymaps.explorer.refresh, function()
      M.refresh(explorer)
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr }))
  end

  -- Navigate to next file
  if config.options.keymaps.view.next_file then
    vim.keymap.set("n", config.options.keymaps.view.next_file, function()
      M.navigate_next(explorer)
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr }))
  end

  -- Navigate to previous file
  if config.options.keymaps.view.prev_file then
    vim.keymap.set("n", config.options.keymaps.view.prev_file, function()
      M.navigate_prev(explorer)
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr }))
  end

  -- Select first file by default (conflicts first, then unstaged, then staged)
  local first_file = nil
  local first_file_group = nil
  if status_result.conflicts and #status_result.conflicts > 0 then
    first_file = status_result.conflicts[1]
    first_file_group = "conflicts"
  elseif #status_result.unstaged > 0 then
    first_file = status_result.unstaged[1]
    first_file_group = "unstaged"
  elseif #status_result.staged > 0 then
    first_file = status_result.staged[1]
    first_file_group = "staged"
  end

  if first_file then
    -- Defer to allow explorer to be fully set up
    vim.defer_fn(function()
      explorer.on_file_select({
        path = first_file.path,
        status = first_file.status,
        git_root = git_root,
        group = first_file_group,
      })
    end, 100)
  end
  
  -- Setup auto-refresh
  M.setup_auto_refresh(explorer, tabpage)
  
  return explorer
end

-- Setup auto-refresh on file save and focus
function M.setup_auto_refresh(explorer, tabpage)
  local refresh_timer = nil
  local debounce_ms = 500  -- Wait 500ms after last event
  
  local function debounced_refresh()
    -- Cancel pending refresh
    if refresh_timer then
      vim.fn.timer_stop(refresh_timer)
    end
    
    -- Schedule new refresh
    refresh_timer = vim.fn.timer_start(debounce_ms, function()
      -- Only refresh if tabpage still exists and explorer is visible
      if vim.api.nvim_tabpage_is_valid(tabpage) and not explorer.is_hidden then
        M.refresh(explorer)
      end
      refresh_timer = nil
    end)
  end
  
  -- Auto-refresh on BufWritePost (file save)
  local group = vim.api.nvim_create_augroup('VscodeDiffExplorerRefresh_' .. tabpage, { clear = true })
  
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function(args)
      -- Only refresh if file is in the same git repo
      local buf_path = vim.api.nvim_buf_get_name(args.buf)
      if buf_path:find(explorer.git_root, 1, true) == 1 then
        debounced_refresh()
      end
    end,
  })
  
  -- Auto-refresh when explorer buffer is entered (user focuses explorer window)
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    buffer = explorer.bufnr,
    callback = function()
      if vim.api.nvim_tabpage_is_valid(tabpage) then
        debounced_refresh()
      end
    end,
  })
  
  -- Clean up on tab close
  vim.api.nvim_create_autocmd('TabClosed', {
    pattern = tostring(tabpage),
    callback = function()
      if refresh_timer then
        vim.fn.timer_stop(refresh_timer)
      end
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

-- Refresh explorer with updated git status
function M.refresh(explorer)
  local git = require('vscode-diff.git')
  
  -- Skip refresh if explorer is hidden
  if explorer.is_hidden then
    return
  end
  
  -- Verify window is still valid before accessing
  if not vim.api.nvim_win_is_valid(explorer.winid) then
    return
  end
  
  -- Get current selection to restore it after refresh
  local current_node = explorer.tree:get_node()
  local current_path = current_node and current_node.data and current_node.data.path
  
  local function process_result(err, status_result)
    vim.schedule(function()
      if err then
        vim.notify("Failed to refresh: " .. err, vim.log.levels.ERROR)
        return
      end
      
      -- Rebuild tree nodes using same structure as create_tree_data
      local root_nodes = create_tree_data(status_result, explorer.git_root, explorer.base_revision)
      
      -- Expand all groups
      for _, node in ipairs(root_nodes) do
        node:expand()
      end
      
      -- Update tree
      explorer.tree:set_nodes(root_nodes)
      explorer.tree:render()
      
      -- Update status result for file selection logic
      explorer.status_result = status_result
      
      -- Try to restore selection
      if current_path then
        local nodes = explorer.tree:get_nodes()
        for _, node in ipairs(nodes) do
          if node.data and node.data.path == current_path then
            explorer.tree:set_node(node:get_id())
            break
          end
        end
      end
    end)
  end
  
  -- Use appropriate git function based on mode
  if explorer.base_revision and explorer.target_revision and explorer.target_revision ~= "WORKING" then
    git.get_diff_revisions(explorer.base_revision, explorer.target_revision, explorer.git_root, process_result)
  elseif explorer.base_revision then
    git.get_diff_revision(explorer.base_revision, explorer.git_root, process_result)
  else
    git.get_status(explorer.git_root, process_result)
  end
end

-- Get flat list of all files from tree (unstaged + staged)
local function get_all_files(tree)
  local files = {}
  local nodes = tree:get_nodes()
  
  for _, group_node in ipairs(nodes) do
    if group_node:is_expanded() and group_node:has_children() then
      for _, file_node in ipairs(group_node:get_child_ids()) do
        local node = tree:get_node(file_node)
        if node and node.data and not node.data.type then
          table.insert(files, {
            node = node,
            data = node.data,
          })
        end
      end
    end
  end
  
  return files
end

-- Navigate to next file in explorer
function M.navigate_next(explorer)
  local all_files = get_all_files(explorer.tree)
  if #all_files == 0 then
    vim.notify("No files in explorer", vim.log.levels.WARN)
    return
  end
  
  -- Use tracked current file path and group
  local current_path = explorer.current_file_path
  local current_group = explorer.current_file_group
  
  -- If no current path, select first file
  if not current_path then
    local first_file = all_files[1]
    explorer.on_file_select(first_file.data)
    return
  end
  
  -- Find current index (match both path AND group for files in both staged/unstaged)
  local current_index = 0
  for i, file in ipairs(all_files) do
    if file.data.path == current_path and file.data.group == current_group then
      current_index = i
      break
    end
  end
  
  -- Get next file (wrap around)
  local next_index = current_index % #all_files + 1
  local next_file = all_files[next_index]
  
  -- Update tree selection visually (switch to explorer window temporarily)
  local current_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(explorer.winid) then
    vim.api.nvim_set_current_win(explorer.winid)
    vim.api.nvim_win_set_cursor(explorer.winid, {next_file.node._line or 1, 0})
    vim.api.nvim_set_current_win(current_win)
  end
  
  -- Trigger file select
  explorer.on_file_select(next_file.data)
end

-- Navigate to previous file in explorer
function M.navigate_prev(explorer)
  local all_files = get_all_files(explorer.tree)
  if #all_files == 0 then
    vim.notify("No files in explorer", vim.log.levels.WARN)
    return
  end
  
  -- Use tracked current file path and group
  local current_path = explorer.current_file_path
  local current_group = explorer.current_file_group
  
  -- If no current path, select last file
  if not current_path then
    local last_file = all_files[#all_files]
    explorer.on_file_select(last_file.data)
    return
  end
  
  -- Find current index (match both path AND group for files in both staged/unstaged)
  local current_index = 0
  for i, file in ipairs(all_files) do
    if file.data.path == current_path and file.data.group == current_group then
      current_index = i
      break
    end
  end
  
  -- Get previous file (wrap around)
  local prev_index = current_index - 2
  if prev_index < 0 then
    prev_index = #all_files + prev_index
  end
  prev_index = prev_index % #all_files + 1
  local prev_file = all_files[prev_index]
  
  -- Update tree selection visually (switch to explorer window temporarily)
  local current_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(explorer.winid) then
    vim.api.nvim_set_current_win(explorer.winid)
    vim.api.nvim_win_set_cursor(explorer.winid, {prev_file.node._line or 1, 0})
    vim.api.nvim_set_current_win(current_win)
  end
  
  -- Trigger file select
  explorer.on_file_select(prev_file.data)
end

-- Toggle explorer visibility (hide/show)
function M.toggle_visibility(explorer)
  if not explorer or not explorer.split then
    return
  end

  -- Track visibility state on the explorer object
  if explorer.is_hidden then
    explorer.split:show()
    explorer.is_hidden = false
    
    -- Update winid after show() creates a new window
    -- NUI creates a new window with a new winid when showing
    explorer.winid = explorer.split.winid
    
    -- Equalize diff windows after showing explorer
    -- When explorer shows, the remaining space should be split equally between diff windows
    vim.schedule(function()
      -- Find diff windows (exclude explorer window)
      local all_wins = vim.api.nvim_tabpage_list_wins(0)
      local diff_wins = {}
      
      for _, win in ipairs(all_wins) do
        if vim.api.nvim_win_is_valid(win) and win ~= explorer.split.winid then
          table.insert(diff_wins, win)
        end
      end
      
      -- Equalize the diff windows (typically 2 windows)
      if #diff_wins >= 2 then
        vim.cmd('wincmd =')
      end
    end)
  else
    explorer.split:hide()
    explorer.is_hidden = true
    
    -- Equalize diff windows after hiding explorer
    vim.schedule(function()
      vim.cmd('wincmd =')
    end)
  end
end

return M
