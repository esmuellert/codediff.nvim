-- Tree data structure building for explorer
-- Handles creating the tree hierarchy from git status
local M = {}

local Tree = require("codediff.ui.lib.tree")
local config = require("codediff.config")
local filter = require("codediff.ui.explorer.filter")
local line_stats = require("codediff.ui.explorer.line_stats")
local nodes = require("codediff.ui.explorer.nodes")

-- Filter files based on explorer.file_filter config
-- Returns files that should be shown (not ignored)
local function filter_files(files)
  local explorer_config = config.options.explorer or {}
  local file_filter = explorer_config.file_filter or {}
  local ignore_patterns = file_filter.ignore or {}

  return filter.apply(files, ignore_patterns)
end

local function create_group_node(label, name, files, children)
  return Tree.Node({
    text = string.format("%s (%d)", label, #files),
    data = {
      type = "group",
      name = name,
      label = label,
      file_count = #files,
      stats = line_stats.sum(files),
      files = files,
    },
  }, children)
end

-- Create tree data structure from git status result
function M.create_tree_data(status_result, git_root, base_revision, is_dir_mode, visible_groups)
  local explorer_config = config.options.explorer or {}
  local view_mode = explorer_config.view_mode or "list"
  visible_groups = visible_groups or explorer_config.visible_groups or {}

  -- Filter merge artifacts and apply file filter
  local unstaged = nodes.filter_merge_artifacts(filter_files(status_result.unstaged))
  local staged = nodes.filter_merge_artifacts(filter_files(status_result.staged))
  local conflicts = status_result.conflicts and nodes.filter_merge_artifacts(filter_files(status_result.conflicts)) or {}

  local create_nodes = (view_mode == "tree") and nodes.create_tree_file_nodes or nodes.create_file_nodes
  local unstaged_nodes = create_nodes(unstaged, git_root, "unstaged")
  local staged_nodes = create_nodes(staged, git_root, "staged")
  local conflict_nodes = create_nodes(conflicts, git_root, "conflicts")

  if is_dir_mode or base_revision then
    -- Dir or revision mode: single group showing all changes.
    -- `get_diff_revision(s)` and `dir.diff_directories` populate `unstaged`;
    -- `get_diff_staged` (--staged, #352) populates `staged`. Pick whichever
    -- has entries — no need for extra flags.
    if #staged > 0 then
      return {
        create_group_node("Staged Changes", "staged", staged, staged_nodes),
      }
    end
    return {
      create_group_node("Changes", "unstaged", unstaged, unstaged_nodes),
    }
  else
    -- Status mode: separate conflicts/staged/unstaged groups
    local tree_nodes = {}

    -- Conflicts first (most important)
    if #conflict_nodes > 0 and visible_groups.conflicts ~= false then
      table.insert(tree_nodes, create_group_node("Merge Changes", "conflicts", conflicts, conflict_nodes))
    end

    -- Unstaged changes
    if visible_groups.unstaged ~= false then
      table.insert(tree_nodes, create_group_node("Changes", "unstaged", unstaged, unstaged_nodes))
    end

    -- Staged changes
    if visible_groups.staged ~= false then
      table.insert(tree_nodes, create_group_node("Staged Changes", "staged", staged, staged_nodes))
    end

    return tree_nodes
  end
end

local function walk_collapsible(tree, visit)
  local function walk(node)
    if not node.data or node.data.type ~= "group" and node.data.type ~= "directory" then
      return
    end
    local key = node.data.path or node.data.name
    if key then
      visit(node, key)
    end
    for _, id in ipairs(node:get_child_ids() or {}) do
      local child = tree:get_node(id)
      if child then
        walk(child)
      end
    end
  end
  for _, node in ipairs(tree:get_nodes()) do
    walk(node)
  end
end

-- Rebuild from supplied data, retaining the user's tree presentation state.
function M.rebuild(explorer)
  local data, tree = explorer.data, explorer.tree
  if not data.status_result then
    return
  end
  local collapsed = {}
  walk_collapsible(tree, function(node, key)
    collapsed[key] = not node:is_expanded()
  end)
  tree:set_nodes(M.create_tree_data(data.status_result, data.git_root, data.base_revision, not data.git_root, explorer.visible_groups))
  walk_collapsible(tree, function(node, key)
    if collapsed[key] then
      node:collapse()
    else
      node:expand()
    end
  end)
  if not explorer.is_hidden then
    tree:render()
  end
end

function M.get_all_files(tree)
  local files = {}
  local function collect(parent)
    if not parent:is_expanded() then
      return
    end
    for _, id in ipairs(parent:get_child_ids() or {}) do
      local node = tree:get_node(id)
      if node and node.data then
        if node.data.type == "directory" then
          collect(node)
        elseif not node.data.type then
          files[#files + 1] = { node = node, data = node.data }
        end
      end
    end
  end
  for _, node in ipairs(tree:get_nodes()) do
    collect(node)
  end
  return files
end

return M
