-- Node creation and formatting for explorer
-- Handles file/directory nodes, icons, status symbols, and tree structure
local M = {}

local Tree = require("nui.tree")
local NuiLine = require("nui.line")
local config = require("codediff.config")

-- Merge artifact patterns (created by git mergetool)
local MERGE_ARTIFACT_PATTERNS = {
  "%.orig$", -- file.orig
  "%.BACKUP%.", -- file.BACKUP.xxxxx
  "%.BASE%.", -- file.BASE.xxxxx
  "%.LOCAL%.", -- file.LOCAL.xxxxx
  "%.REMOTE%.", -- file.REMOTE.xxxxx
  "_BACKUP_%d+%.", -- file_BACKUP_xxxxx.ext
  "_BASE_%d+%.", -- file_BASE_xxxxx.ext
  "_LOCAL_%d+%.", -- file_LOCAL_xxxxx.ext
  "_REMOTE_%d+%.", -- file_REMOTE_xxxxx.ext
  "_BACKUP_%d+$", -- file_BACKUP_xxxxx
  "_BASE_%d+$", -- file_BASE_xxxxx
  "_LOCAL_%d+$", -- file_LOCAL_xxxxx
  "_REMOTE_%d+$", -- file_REMOTE_xxxxx
}

-- Status symbols and colors
local STATUS_SYMBOLS = {
  M = { symbol = "M", color = "DiagnosticWarn" },
  A = { symbol = "A", color = "DiagnosticOk" },
  D = { symbol = "D", color = "DiagnosticError" },
  ["??"] = { symbol = "??", color = "DiagnosticInfo" },
  ["!"] = { symbol = "!", color = "DiagnosticError" }, -- Merge conflict
}

-- Indent marker characters (neo-tree style)
local INDENT_MARKERS = {
  edge = "│", -- Vertical line for non-last items
  item = "├", -- Branch for non-last items
  last = "└", -- Branch for last item
  none = " ", -- Space when parent was last item
}

-- Check if a file path matches merge artifact patterns
local function is_merge_artifact(path)
  for _, pattern in ipairs(MERGE_ARTIFACT_PATTERNS) do
    if path:match(pattern) then
      return true
    end
  end
  return false
end

-- Filter out merge artifacts from file list
function M.filter_merge_artifacts(files)
  if not config.options.diff.hide_merge_artifacts then
    return files
  end

  local filtered = {}
  for _, file in ipairs(files) do
    if not is_merge_artifact(file.path) then
      table.insert(filtered, file)
    end
  end
  return filtered
end

-- File icons (basic fallback)
function M.get_file_icon(path)
  local has_devicons, devicons = pcall(require, "nvim-web-devicons")
  if has_devicons then
    local icon, color = devicons.get_icon(path, nil, { default = true })
    return icon or "", color
  end
  return "", nil
end

-- Folder icon (configurable via config, with nerd font defaults)
function M.get_folder_icon(is_open)
  local explorer_config = config.options.explorer or {}
  local icons = explorer_config.icons or {}
  local defaults = config.defaults.explorer.icons
  if is_open then
    return icons.folder_open or defaults.folder_open, "Directory"
  else
    return icons.folder_closed or defaults.folder_closed, "Directory"
  end
end

-- Create flat file nodes (list mode)
function M.create_file_nodes(files, git_root, group)
  local nodes = {}
  for _, file in ipairs(files) do
    local icon, icon_color = M.get_file_icon(file.path)
    local status_info = STATUS_SYMBOLS[file.status] or { symbol = file.status, color = "Normal" }

    nodes[#nodes + 1] = Tree.Node({
      text = file.path,
      data = {
        path = file.path,
        status = file.status,
        old_path = file.old_path, -- For renames: original path before rename
        icon = icon,
        icon_color = icon_color,
        status_symbol = status_info.symbol,
        status_color = status_info.color,
        git_root = git_root,
        group = group,
      },
    })
  end
  return nodes
end

-- Create tree nodes with directory hierarchy (tree mode)
function M.create_tree_file_nodes(files, git_root, group)
  -- Build directory structure
  local dir_tree = {}

  for _, file in ipairs(files) do
    local parts = {}
    for part in file.path:gmatch("[^/]+") do
      parts[#parts + 1] = part
    end

    local current = dir_tree
    for i = 1, #parts - 1 do
      local dir_name = parts[i]
      if not current[dir_name] then
        current[dir_name] = { _is_dir = true, _children = {} }
      end
      current = current[dir_name]._children
    end

    -- Add file at leaf
    local filename = parts[#parts]
    current[filename] = {
      _is_dir = false,
      _file = file,
    }
  end

  -- Convert to Tree.Node recursively
  -- indent_state: array of booleans, true = ancestor at that level is last child
  local function build_nodes(subtree, parent_path, indent_state)
    local nodes = {}
    local sorted_keys = {}

    for key in pairs(subtree) do
      sorted_keys[#sorted_keys + 1] = key
    end
    -- Sort: directories first, then files, alphabetically
    table.sort(sorted_keys, function(a, b)
      local a_is_dir = subtree[a]._is_dir
      local b_is_dir = subtree[b]._is_dir
      if a_is_dir ~= b_is_dir then
        return a_is_dir
      end
      return a < b
    end)

    local total = #sorted_keys
    for idx, key in ipairs(sorted_keys) do
      local item = subtree[key]
      local full_path = parent_path ~= "" and (parent_path .. "/" .. key) or key
      local is_last = (idx == total)

      -- Copy parent indent state and add current level
      local node_indent_state = {}
      for i, v in ipairs(indent_state) do
        node_indent_state[i] = v
      end
      node_indent_state[#node_indent_state + 1] = is_last

      if item._is_dir then
        -- Directory node - children need to know this dir's is_last status
        local children = build_nodes(item._children, full_path, node_indent_state)
        nodes[#nodes + 1] = Tree.Node({
          text = key,
          data = {
            type = "directory",
            name = key,
            dir_path = full_path,
            group = group,
            indent_state = node_indent_state,
          },
        }, children)
      else
        -- File node
        local file = item._file
        local icon, icon_color = M.get_file_icon(file.path)
        local status_info = STATUS_SYMBOLS[file.status] or { symbol = file.status, color = "Normal" }

        nodes[#nodes + 1] = Tree.Node({
          text = key,
          data = {
            path = file.path,
            status = file.status,
            old_path = file.old_path,
            icon = icon,
            icon_color = icon_color,
            status_symbol = status_info.symbol,
            status_color = status_info.color,
            git_root = git_root,
            group = group,
            indent_state = node_indent_state,
          },
        })
      end
    end

    return nodes
  end

  return build_nodes(dir_tree, "", {})
end

-- Prepare node for rendering (format display)
function M.prepare_node(node, max_width, selected_path, selected_group)
  local line = NuiLine()
  local data = node.data or {}
  local explorer_config = config.options.explorer or {}
  local use_indent_markers = explorer_config.indent_markers ~= false -- default true

  -- Helper to build indent string with markers (for tree mode)
  local function build_indent_markers(indent_state)
    if not indent_state or #indent_state == 0 then
      return ""
    end

    if not use_indent_markers then
      -- Plain space indentation
      return string.rep("  ", #indent_state)
    end

    local indent_parts = {}
    -- All levels except the last one: show edge or space
    for i = 1, #indent_state - 1 do
      if indent_state[i] then
        -- Ancestor was last child, show space
        indent_parts[#indent_parts + 1] = INDENT_MARKERS.none .. " "
      else
        -- Ancestor was not last, show edge
        indent_parts[#indent_parts + 1] = INDENT_MARKERS.edge .. " "
      end
    end
    -- Last level: show item or last marker
    if indent_state[#indent_state] then
      indent_parts[#indent_parts + 1] = INDENT_MARKERS.last .. " "
    else
      indent_parts[#indent_parts + 1] = INDENT_MARKERS.item .. " "
    end
    return table.concat(indent_parts)
  end

  if data.type == "group" then
    -- Group header
    line:append(" ", "Directory")
    line:append(node.text, "Directory")
  elseif data.type == "directory" then
    -- Directory node (tree view mode) - with indent markers
    local indent = build_indent_markers(data.indent_state)
    local folder_icon, folder_color = M.get_folder_icon(node:is_expanded())
    if #indent > 0 then
      line:append(indent, use_indent_markers and "NeoTreeIndentMarker" or "Normal")
    end
    line:append(folder_icon .. " ", folder_color or "Directory")
    line:append(data.name, "Directory")
  else
    -- Match both path AND group to handle files in both staged and unstaged
    local is_selected = data.path and data.path == selected_path and data.group == selected_group

    -- Get selected background color once
    local selected_bg = nil
    if is_selected then
      local sel_hl = vim.api.nvim_get_hl(0, { name = "CodeDiffExplorerSelected", link = false })
      selected_bg = sel_hl.bg
    end

    -- Helper to get highlight with selected background but original foreground
    local function get_hl(default)
      if not is_selected then
        return default or "Normal"
      end
      -- Create a combined highlight: original fg + selected bg
      local base_hl_name = default or "Normal"
      local combined_name = "CodeDiffExplorerSel_" .. base_hl_name:gsub("[^%w]", "_")

      -- Get foreground from base highlight
      local base_hl = vim.api.nvim_get_hl(0, { name = base_hl_name, link = false })
      local fg = base_hl.fg

      -- Set the combined highlight (will be cached by nvim)
      vim.api.nvim_set_hl(0, combined_name, { fg = fg, bg = selected_bg })
      return combined_name
    end

    -- Check if we're in tree mode (directory is already shown in hierarchy)
    local view_mode = explorer_config.view_mode or "list"

    -- File entry - VSCode style: filename (bold) + directory (dimmed) + status (right-aligned)
    local indent
    if view_mode == "tree" and data.indent_state then
      indent = build_indent_markers(data.indent_state)
      if #indent > 0 then
        line:append(indent, get_hl(use_indent_markers and "NeoTreeIndentMarker" or "Normal"))
      end
    else
      indent = string.rep("  ", node:get_depth() - 1)
      line:append(indent, get_hl("Normal"))
    end

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
    -- In tree mode, don't show directory (it's in the hierarchy)
    local directory = (view_mode == "tree") and "" or full_path:sub(1, -(#filename + 1))

    -- Calculate how much width we've used and reserve for status
    local used_width = vim.fn.strdisplaywidth(indent) + vim.fn.strdisplaywidth(icon_part)
    local status_reserve = vim.fn.strdisplaywidth(status_symbol) + 3 -- 2 spaces before + 1 space after status
    local available_for_content = max_width - used_width - status_reserve

    -- Show: filename + full directory path, truncate directory from left if needed
    local filename_len = vim.fn.strdisplaywidth(filename)
    local directory_len = vim.fn.strdisplaywidth(directory)
    local space_len = (directory_len > 0) and 1 or 0

    if filename_len + space_len + directory_len > available_for_content then
      -- Truncate directory from the right (keep the start)
      local available_for_dir = available_for_content - filename_len - space_len
      if available_for_dir > 3 then
        local ellipsis = "..."
        local chars_to_keep = available_for_dir - vim.fn.strdisplaywidth(ellipsis)

        -- Truncate directory by display width, not byte index
        local byte_pos = 0
        local accumulated_width = 0
        for char in vim.gsplit(directory, "") do
          local char_width = vim.fn.strdisplaywidth(char)
          if accumulated_width + char_width > chars_to_keep then
            break
          end
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

    -- Append filename (normal weight) and directory (dimmed)
    line:append(filename, get_hl("Normal"))
    if #directory > 0 then
      line:append(" ", get_hl("Normal"))
      line:append(directory, get_hl("ExplorerDirectorySmall"))
    end

    -- Add padding to push status symbol to the right edge
    local content_len = vim.fn.strdisplaywidth(filename) + space_len + vim.fn.strdisplaywidth(directory)
    local padding_needed = available_for_content - content_len + 2
    if padding_needed > 0 then
      line:append(string.rep(" ", padding_needed), get_hl("Normal"))
    end
    line:append(status_symbol, get_hl(data.status_color))
    line:append(" ", get_hl("Normal")) -- Right padding (matches status_reserve calculation)
  end

  return line
end

return M
