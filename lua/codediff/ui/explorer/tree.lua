-- Tree data structure building for explorer
-- Handles creating the tree hierarchy from git status
local M = {}

local Tree = require("nui.tree")
local config = require("codediff.config")
local filter = require("codediff.ui.explorer.filter")

-- Will be injected by init.lua
local nodes = nil
M._set_nodes_module = function(n)
  nodes = n
end

-- Filter files based on explorer.file_filter config
-- Returns files that should be shown (not ignored)
local function filter_files(files)
  local explorer_config = config.options.explorer or {}
  local file_filter = explorer_config.file_filter or {}
  local ignore_patterns = file_filter.ignore or {}

  return filter.apply(files, ignore_patterns)
end

-- Create tree data structure from git status result
function M.create_tree_data(status_result, git_root, base_revision, is_dir_mode)
  local explorer_config = config.options.explorer or {}
  local view_mode = explorer_config.view_mode or "list"

  -- Filter merge artifacts and apply file filter
  local unstaged = nodes.filter_merge_artifacts(filter_files(status_result.unstaged))
  local staged = nodes.filter_merge_artifacts(filter_files(status_result.staged))
  local conflicts = status_result.conflicts and nodes.filter_merge_artifacts(filter_files(status_result.conflicts)) or {}

  local create_nodes = (view_mode == "tree") and nodes.create_tree_file_nodes or nodes.create_file_nodes
  local unstaged_nodes = create_nodes(unstaged, git_root, "unstaged")
  local staged_nodes = create_nodes(staged, git_root, "staged")
  local conflict_nodes = create_nodes(conflicts, git_root, "conflicts")

  if is_dir_mode or base_revision then
    -- Dir or revision mode: single group showing all changes
    return {
      Tree.Node({
        text = string.format("Changes (%d)", #unstaged),
        data = { type = "group", name = "unstaged" },
      }, unstaged_nodes),
    }
  else
    -- Status mode: separate conflicts/staged/unstaged groups
    local tree_nodes = {}

    -- Conflicts first (most important)
    if #conflict_nodes > 0 then
      table.insert(
        tree_nodes,
        Tree.Node({
          text = string.format("Merge Changes (%d)", #conflicts),
          data = { type = "group", name = "conflicts" },
        }, conflict_nodes)
      )
    end

    -- Unstaged changes
    table.insert(
      tree_nodes,
      Tree.Node({
        text = string.format("Changes (%d)", #unstaged),
        data = { type = "group", name = "unstaged" },
      }, unstaged_nodes)
    )

    -- Staged changes
    table.insert(
      tree_nodes,
      Tree.Node({
        text = string.format("Staged Changes (%d)", #staged),
        data = { type = "group", name = "staged" },
      }, staged_nodes)
    )

    return tree_nodes
  end
end

return M
