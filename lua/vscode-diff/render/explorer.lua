-- Git status explorer using nui.nvim
local M = {}

local Tree = require("nui.tree")
local NuiLine = require("nui.line")
local Split = require("nui.split")

-- Status symbols and colors
local STATUS_SYMBOLS = {
  M = { symbol = "M", color = "DiagnosticWarn" },
  A = { symbol = "A", color = "DiagnosticOk" },
  D = { symbol = "D", color = "DiagnosticError" },
  ["??"] = { symbol = "??", color = "DiagnosticInfo" },
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
local function create_tree_data(status_result, git_root)
  local unstaged_nodes = create_file_nodes(status_result.unstaged, git_root, "unstaged")
  local staged_nodes = create_file_nodes(status_result.staged, git_root, "staged")

  return {
    Tree.Node({
      text = string.format("Changes (%d)", #status_result.unstaged),
      data = { type = "group", name = "unstaged" },
    }, unstaged_nodes),
    Tree.Node({
      text = string.format("Staged Changes (%d)", #status_result.staged),
      data = { type = "group", name = "staged" },
    }, staged_nodes),
  }
end

-- Render tree node
local function prepare_node(node, max_width)
  local line = NuiLine()
  local data = node.data or {}

  if data.type == "group" then
    -- Group header
    local icon = node:is_expanded() and "" or ""
    line:append(icon .. " ", "Directory")
    line:append(node.text, "Directory")
  else
    -- File entry - VSCode style: filename (bold) + directory (dimmed) + status (right-aligned)
    local indent = string.rep("  ", node:get_depth() - 1)
    line:append(indent)
    
    local icon_part = ""
    if data.icon then
      icon_part = data.icon .. " "
      line:append(icon_part, data.icon_color or "Normal")
    end
    
    -- Status symbol at the end (e.g., "M", "D", "??")
    local status_symbol = data.status_symbol or ""
    
    -- Split path into filename and directory
    local full_path = data.path or node.text
    local filename = full_path:match("([^/]+)$") or full_path
    local directory = full_path:sub(1, -(#filename + 1))  -- Remove filename, keep trailing /
    
    -- Calculate how much width we've used and reserve for status
    local used_width = #indent + #icon_part
    local status_reserve = #status_symbol + 2  -- 2 spaces padding before status
    local available_for_content = max_width - used_width - status_reserve
    
    -- VSCode shows: filename + directory (dimmed), truncate directory if needed
    local filename_len = #filename
    local directory_len = #directory
    local space_len = (#directory > 0) and 1 or 0  -- Account for space between filename and directory
    
    if filename_len + space_len + directory_len > available_for_content then
      -- Prioritize showing full filename, truncate directory from end (right)
      local available_for_dir = available_for_content - filename_len - space_len
      if available_for_dir > 3 then
        -- Show truncated directory (from the start, hide the end)
        local ellipsis = "..."
        local chars_to_keep = available_for_dir - #ellipsis
        directory = directory:sub(1, chars_to_keep) .. ellipsis
      else
        -- Not enough space for directory, just show filename
        directory = ""
        space_len = 0
      end
    end
    
    -- Append filename (normal weight) and directory (dimmed with smaller font)
    line:append(filename, "Normal")
    if #directory > 0 then
      line:append(" ", "Normal")
      line:append(directory, "ExplorerDirectorySmall")  -- Smaller dimmed style
    end
    
    -- Add padding to push status symbol to the right edge
    local content_len = #filename + space_len + #directory
    local padding_needed = available_for_content - content_len + 2
    if padding_needed > 0 then
      line:append(string.rep(" ", padding_needed))
    end
    line:append(status_symbol, data.status_color or "Normal")
  end

  return line
end

-- Create and show explorer
function M.create(status_result, git_root, tabpage, width)
  -- Use provided width or default to 40 columns (same as neo-tree)
  local explorer_width = width or 40
  
  -- File selection callback - manages its own lifecycle
  local function on_file_select(file_data)
    local git = require('vscode-diff.git')
    local view = require('vscode-diff.render.view')
    local lifecycle = require('vscode-diff.render.lifecycle')
    
    local file_path = file_data.path
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

    -- Resolve HEAD to commit hash first
    git.resolve_revision("HEAD", git_root, function(err_resolve, commit_hash)
      if err_resolve then
        vim.schedule(function()
          vim.notify(err_resolve, vim.log.levels.ERROR)
        end)
        return
      end

      if group == "staged" then
        -- Staged changes: Compare staged (:0) vs HEAD (both virtual)
        -- No pre-fetching needed, virtual files will load via BufReadCmd
        vim.schedule(function()
          ---@type SessionConfig
          local session_config = {
            mode = "explorer",
            git_root = git_root,
            original_path = file_path,
            modified_path = file_path,
            original_revision = commit_hash,
            modified_revision = ":0",
          }
          view.update(tabpage, session_config, true)
        end)
      else
        -- Unstaged changes: Compare working tree vs staged (if exists) or HEAD
        -- Check if file is in staged list
        local is_staged = false
        for _, staged_file in ipairs(status_result.staged) do
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
    },
  })

  -- Mount split first to get bufnr
  split:mount()

  -- Create tree with buffer number
  local tree_data = create_tree_data(status_result, git_root)
  local tree = Tree({
    bufnr = split.bufnr,
    nodes = tree_data,
    prepare_node = function(node)
      return prepare_node(node, explorer_width)
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

  -- Keymaps
  local map_options = { noremap = true, silent = true, nowait = true }

  -- Toggle expand/collapse
  vim.keymap.set("n", "<CR>", function()
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
        on_file_select(node.data)
      end
    end
  end, vim.tbl_extend("force", map_options, { buffer = split.bufnr }))

  -- Double click also works for files
  vim.keymap.set("n", "<2-LeftMouse>", function()
    local node = tree:get_node()
    if not node or not node.data or node.data.type == "group" then return end
    on_file_select(node.data)
  end, vim.tbl_extend("force", map_options, { buffer = split.bufnr }))

  -- Close explorer (disabled)
  -- vim.keymap.set("n", "q", function()
  --   split:unmount()
  -- end, vim.tbl_extend("force", map_options, { buffer = split.bufnr }))
  
  -- Hover to show full path (K key, like LSP hover)
  local hover_win = nil
  vim.keymap.set("n", "K", function()
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

  -- Select first file by default
  local first_file = nil
  local first_file_group = nil
  if #status_result.unstaged > 0 then
    first_file = status_result.unstaged[1]
    first_file_group = "unstaged"
  elseif #status_result.staged > 0 then
    first_file = status_result.staged[1]
    first_file_group = "staged"
  end

  if first_file then
    -- Defer to allow explorer to be fully set up
    vim.defer_fn(function()
      on_file_select({
        path = first_file.path,
        status = first_file.status,
        git_root = git_root,
        group = first_file_group,
      })
    end, 100)
  end

  return {
    split = split,
    tree = tree,
    bufnr = split.bufnr,
    winid = split.winid,
  }
end

return M
