-- Node creation and formatting for explorer
-- Handles file/directory nodes, icons, status symbols, and tree structure
local M = {}

local Tree = require("codediff.ui.lib.tree")
local config = require("codediff.config")
local line_layout = require("codediff.ui.explorer.line_layout")
local line_stats = require("codediff.ui.explorer.line_stats")
local default_formatters = require("codediff.ui.explorer.formatters")

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
  M = { symbol = "M", color = "CodeDiffStatusModified" },
  A = { symbol = "A", color = "CodeDiffStatusAdded" },
  D = { symbol = "D", color = "CodeDiffStatusDeleted" },
  ["??"] = { symbol = "??", color = "CodeDiffStatusUntracked" },
  ["!"] = { symbol = "!", color = "CodeDiffStatusConflict" },
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

local function context_stats(stats)
  if not config.options.explorer.line_stats.enabled then
    return nil
  end
  return vim.deepcopy(stats)
end

local function normalize_files(files, group)
  local normalized = {}
  for _, file in ipairs(files or {}) do
    normalized[#normalized + 1] = {
      path = file.path,
      old_path = file.old_path,
      group = group or file.group,
      status = file.status,
      stats = context_stats(file.line_stats),
    }
  end
  return normalized
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
        line_stats = file.line_stats,
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
      -- Git can report a file and a directory at the same path.
      local dir_key = "/" .. parts[i]
      local directory = current[dir_key]
      if not directory then
        directory = { _is_dir = true, _children = {}, _files = {} }
        current[dir_key] = directory
      end
      directory._files[#directory._files + 1] = file
      current = directory._children
    end

    -- Add file at leaf
    local filename = parts[#parts]
    current[filename] = {
      _is_dir = false,
      _file = file,
    }
  end

  -- Flatten single-child directory chains (e.g., src/ -> components/ -> ui/ becomes src/components/ui/)
  local function flatten_tree(subtree)
    for key, item in pairs(subtree) do
      if item._is_dir then
        flatten_tree(item._children)
        -- Check if this dir has exactly one child and it's a directory
        local children_keys = {}
        for k in pairs(item._children) do
          children_keys[#children_keys + 1] = k
        end
        if #children_keys == 1 and item._children[children_keys[1]]._is_dir then
          local child_key = children_keys[1]
          local child = item._children[child_key]
          local merged_key = key .. child_key
          subtree[merged_key] = child
          subtree[key] = nil
        end
      end
    end
  end

  local explorer_config = config.options.explorer or {}
  if explorer_config.flatten_dirs ~= false then
    flatten_tree(dir_tree)
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
      local is_last = (idx == total)

      -- Copy parent indent state and add current level
      local node_indent_state = {}
      for i, v in ipairs(indent_state) do
        node_indent_state[i] = v
      end
      node_indent_state[#node_indent_state + 1] = is_last

      if item._is_dir then
        -- Directory node - children need to know this dir's is_last status
        local name = key:sub(2)
        local full_path = parent_path ~= "" and (parent_path .. "/" .. name) or name
        local children = build_nodes(item._children, full_path, node_indent_state)
        nodes[#nodes + 1] = Tree.Node({
          text = name,
          data = {
            type = "directory",
            name = name,
            dir_path = full_path,
            group = group,
            indent_state = node_indent_state,
            file_count = #item._files,
            stats = line_stats.sum(item._files),
            files = item._files,
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
            line_stats = file.line_stats,
          },
        })
      end
    end

    return nodes
  end

  return build_nodes(dir_tree, "", {})
end

local function build_indent_markers(indent_state, use_indent_markers)
  if not indent_state or #indent_state == 0 then
    return ""
  end
  if not use_indent_markers then
    return string.rep("  ", #indent_state)
  end

  local parts = {}
  for index = 1, #indent_state - 1 do
    parts[#parts + 1] = (indent_state[index] and INDENT_MARKERS.none or INDENT_MARKERS.edge) .. " "
  end
  parts[#parts + 1] = (indent_state[#indent_state] and INDENT_MARKERS.last or INDENT_MARKERS.item) .. " "
  return table.concat(parts)
end

local function get_indent(node, data, explorer_config)
  local use_indent_markers = explorer_config.indent_markers ~= false
  if explorer_config.view_mode == "tree" and data.indent_state then
    return build_indent_markers(data.indent_state, use_indent_markers), use_indent_markers and "NeoTreeIndentMarker" or "Normal"
  end
  return string.rep("  ", node:get_depth() - 1), "Normal"
end

local function group_context(node, data)
  return {
    name = data.name,
    label = data.label,
    file_count = data.file_count,
    stats = context_stats(data.stats),
    files = normalize_files(data.files, data.name),
    expanded = node:is_expanded(),
  }
end

local function folder_context(node, data, explorer_config)
  local indent, indent_hl = get_indent(node, data, explorer_config)
  local icon, icon_hl = M.get_folder_icon(node:is_expanded())
  return {
    name = data.name,
    path = data.dir_path,
    group = data.group,
    file_count = data.file_count,
    stats = context_stats(data.stats),
    files = normalize_files(data.files, data.group),
    indent = indent,
    indent_hl = indent_hl,
    icon = icon,
    icon_hl = icon_hl,
    expanded = node:is_expanded(),
  }
end

local function file_context(node, data, explorer_config)
  local indent, indent_hl = get_indent(node, data, explorer_config)
  local full_path = data.path or node.text
  local filename = full_path:match("([^/]+)$") or full_path
  local directory = explorer_config.view_mode == "tree" and "" or full_path:sub(1, -(#filename + 1))
  return {
    path = full_path,
    filename = filename,
    directory = directory,
    old_path = data.old_path,
    group = data.group,
    stats = context_stats(data.line_stats),
    status = data.status_symbol or "",
    status_hl = data.status_color,
    status_right_margin = math.max(0, explorer_config.status_right_margin or 1),
    indent = indent,
    indent_hl = indent_hl,
    icon = data.icon or "",
    icon_hl = data.icon_color,
  }
end

local function selected_background(is_selected)
  if not is_selected then
    return nil
  end
  return vim.api.nvim_get_hl(0, { name = "CodeDiffExplorerSelected", link = false }).bg
end

-- Prepare node for rendering (format display)
function M.prepare_node(node, max_width, selected_path, selected_group)
  local data = node.data or {}
  local explorer_config = config.options.explorer
  -- Formatters are pluggable per node type; nil in config means "use the
  -- built-in default" (see `default_formatters` at the top of this file).
  local user_formatters = explorer_config.formatters or {}
  if data.type == "group" then
    local fmt = user_formatters.group or default_formatters.group
    return line_layout.render(fmt(group_context(node, data)), max_width, nil, explorer_config.ellipsis)
  end
  if data.type == "directory" then
    local fmt = user_formatters.folder or default_formatters.folder
    return line_layout.render(fmt(folder_context(node, data, explorer_config)), max_width, nil, explorer_config.ellipsis)
  end

  local is_selected = data.path == selected_path and data.group == selected_group
  local fmt = user_formatters.file or default_formatters.file
  return line_layout.render(fmt(file_context(node, data, explorer_config)), max_width, selected_background(is_selected), explorer_config.ellipsis)
end

return M
