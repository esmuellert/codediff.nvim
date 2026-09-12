-- Auto-refresh and refresh logic for explorer
local M = {}

local config = require("codediff.config")
local tree_module = require("codediff.ui.explorer.tree")
local welcome = require("codediff.ui.welcome")
local scheduler = require("codediff.ui.explorer.refresh.scheduler")

-- Setup native repository watching with polling as startup/runtime fallback.
function M.setup_auto_refresh(explorer, tabpage)
  return scheduler.setup(explorer, tabpage, M._refresh_once)
end

--- Walk every group and directory node beneath `root_nodes`, calling `visit`
--- with the node and the key it is remembered by.
--- @param visit fun(node: table, key: string)
local function walk_collapsible(tree, root_nodes, visit)
  local function walk(node)
    if not node.data then
      return
    end
    local node_type = node.data.type
    if node_type ~= "group" and node_type ~= "directory" then
      return
    end
    -- Directories are keyed by path, groups by name.
    local key = node.data.path or node.data.name
    if key then
      visit(node, key)
    end
    if node:has_children() then
      for _, child_id in ipairs(node:get_child_ids()) do
        local child = tree:get_node(child_id)
        if child then
          walk(child)
        end
      end
    end
  end

  for _, node in ipairs(root_nodes) do
    walk(node)
  end
end

--- Which collapsible nodes are collapsed, keyed for restoring later.
local function collect_collapsed_state(tree)
  local collapsed = {}
  walk_collapsible(tree, tree:get_nodes(), function(node, key)
    if not node:is_expanded() then
      collapsed[key] = true
    end
  end)
  return collapsed
end

--- Re-collapse whatever was collapsed before the tree was rebuilt.
local function restore_collapsed_state(tree, collapsed, root_nodes)
  walk_collapsible(tree, root_nodes, function(node, key)
    if collapsed[key] then
      node:collapse()
    end
  end)
end

--- The reviewed file's slot in its group, read off the status from before the
--- refresh. file_to_reselect needs it to find whatever takes that slot.
--- @param explorer table
--- @return number|nil
local function reviewed_file_index(explorer)
  local group = explorer.current_file_group
  if not group then
    return nil
  end
  for i, f in ipairs((explorer.status_result or {})[group] or {}) do
    if f.path == explorer.current_file_path then
      return i
    end
  end
  return nil
end

--- Forget which file was being reviewed, panel selection included.
--- @param explorer table
local function clear_current_file(explorer)
  explorer.current_file_path = nil
  explorer.current_file_group = nil
  explorer.current_selection = nil
  if explorer.clear_selection then
    explorer.clear_selection()
  end
end

--- Which file the explorer should show after a refresh, and in which group.
---
--- Prefer the same group the reviewer was in: hunk staging leaves the file
--- where it was. When the file left that group entirely -- fully staged or
--- unstaged -- take whatever now occupies its slot there, so staging walks
--- down the unstaged list instead of chasing the file into the staged one
--- (#347). Only if the group has nothing left does the search follow the file.
---
--- @param explorer table
--- @param status_result table
--- @param prev_index number? The file's slot in its group before the refresh
--- @return table|nil file, string|nil group
local function file_to_reselect(explorer, status_result, prev_index)
  local group_lists = {
    unstaged = status_result.unstaged,
    staged = status_result.staged,
    conflicts = status_result.conflicts,
  }
  local current_group = explorer.current_file_group

  local function search(files, group_name)
    for _, f in ipairs(files or {}) do
      if f.path == explorer.current_file_path then
        return f, group_name
      end
    end
    return nil, nil
  end

  if current_group then
    local found, group = search(group_lists[current_group], current_group)
    if found then
      return found, group
    end
  end

  if current_group and prev_index then
    local same_group = group_lists[current_group]
    if same_group and #same_group > 0 then
      return same_group[math.min(prev_index, #same_group)], current_group
    end
  end

  for _, group_name in ipairs({ "conflicts", "unstaged", "staged" }) do
    local found, group = search(status_result[group_name], group_name)
    if found then
      return found, group
    end
  end

  return nil, nil
end

-- Rebuild the explorer tree from a status_result and re-render, honoring the
-- current group visibility. Runs synchronously (no vim.schedule), so callers in
-- a normal context — e.g. toggling a group — get an immediately consistent tree.
local function rebuild_tree(explorer, status_result, collapsed_state)
  local root_nodes = tree_module.create_tree_data(status_result, explorer.git_root, explorer.base_revision, not explorer.git_root, explorer.visible_groups)

  -- Expand all groups
  for _, node in ipairs(root_nodes) do
    node:expand()
  end

  -- Update tree
  explorer.tree:set_nodes(root_nodes)

  -- For tree mode, expand directories after setting nodes
  local explorer_config = config.options.explorer or {}
  if explorer_config.view_mode == "tree" then
    local function expand_all_dirs(parent_node)
      if not parent_node:has_children() then
        return
      end
      for _, child_id in ipairs(parent_node:get_child_ids()) do
        local child = explorer.tree:get_node(child_id)
        if child and child.data and child.data.type == "directory" then
          child:expand()
          expand_all_dirs(child)
        end
      end
    end
    for _, node in ipairs(root_nodes) do
      expand_all_dirs(node)
    end
  end

  -- Restore user's collapsed state (must be after expand_all_dirs)
  restore_collapsed_state(explorer.tree, collapsed_state, root_nodes)

  if not explorer.is_hidden then
    explorer.tree:render()
  end
end

-- Execute one explorer refresh. Public callers use M.refresh below.
function M._refresh_once(explorer, done)
  local git = require("codediff.core.git")
  local completed = false
  local function complete(err)
    if completed then
      return
    end
    completed = true
    if done then
      done(err)
    end
  end

  -- A hidden panel still supplies status and comparison definitions.
  if not explorer.is_hidden and not vim.api.nvim_win_is_valid(explorer.winid) then
    complete()
    return
  end

  -- Collect collapsed state before async operation
  local collapsed_state = collect_collapsed_state(explorer.tree)

  local function process_result(err, status_result)
    vim.schedule(function()
      local lifecycle = require("codediff.ui.lifecycle")
      if lifecycle.get_panel_view(explorer.tabpage) ~= explorer or (not explorer.is_hidden and not vim.api.nvim_win_is_valid(explorer.winid)) then
        complete()
        return
      end

      if err then
        complete(err)
        return
      end

      -- Panel equality does not suppress the controller's input inspection.
      if vim.deep_equal(status_result, explorer.status_result) then
        complete()
        return
      end

      -- Rebuild tree nodes (honors group visibility) and re-render.
      rebuild_tree(explorer, status_result, collapsed_state)

      -- Read before status_result is replaced below.
      local prev_index = reviewed_file_index(explorer)
      explorer.status_result = status_result

      local show_welcome_page = require("codediff.ui.explorer.render").show_welcome_page

      -- Show welcome page when all files are clean (skip if already showing)
      local total_files = #(status_result.unstaged or {}) + #(status_result.staged or {}) + #(status_result.conflicts or {})
      if total_files == 0 then
        local session = lifecycle.get_session(explorer.tabpage)
        local already_welcome = session and welcome.is_welcome_buffer(session.modified_bufnr)
        clear_current_file(explorer)
        if not already_welcome then
          show_welcome_page(explorer)
        end
      end

      -- Re-select the currently viewed file after refresh.
      -- Search all file children across all groups for the current file.
      -- If found (possibly in a new group), call on_file_select to update diff panes.
      -- If not found (committed/removed), show welcome page.
      if explorer.current_file_path and total_files > 0 then
        local found_file, found_group = file_to_reselect(explorer, status_result, prev_index)
        if found_file then
          local selected = explorer.current_selection
          if
            not selected
            or selected.path ~= found_file.path
            or selected.group ~= found_group
            or selected.status ~= found_file.status
            or selected.old_path ~= found_file.old_path
          then
            explorer.on_file_select({
              path = found_file.path,
              old_path = found_file.old_path,
              status = found_file.status,
              git_root = explorer.git_root,
              group = found_group,
            }, { no_jump = true })
          end
        else
          -- Committed or removed.
          clear_current_file(explorer)
          show_welcome_page(explorer)
        end
      end
      complete()
    end)
  end

  local function fetch_status()
    -- Use appropriate function based on mode
    if not explorer.git_root then
      -- Dir mode: re-scan directories
      local dir_mod = require("codediff.core.dir")
      local diff = dir_mod.diff_directories(explorer.dir1, explorer.dir2)
      process_result(nil, diff.status_result)
    elseif explorer.target_revision == ":0" then
      -- Staged-only mode (--staged): index vs base_revision. `git diff base :0`
      -- isn't a valid rev-pair; use `git diff --cached base` instead.
      git.get_diff_staged(explorer.base_revision, explorer.git_root, process_result, explorer.pathspec)
    elseif explorer.base_revision and explorer.target_revision and explorer.target_revision ~= "WORKING" then
      git.get_diff_revisions_with_line_stats(explorer.base_revision, explorer.target_revision, explorer.git_root, process_result, explorer.pathspec)
    elseif explorer.base_revision then
      git.get_diff_revision_with_line_stats(explorer.base_revision, explorer.git_root, process_result, explorer.pathspec)
    else
      git.get_status_with_line_stats(explorer.git_root, process_result, explorer.pathspec)
    end
  end

  local requested = explorer.source_revisions
  if not requested then
    fetch_status()
    return
  end
  local resolved, remaining, failure = {}, 1, nil
  local function settled(err)
    failure = failure or err
    remaining = remaining - 1
    if remaining ~= 0 then
      return
    end
    if failure then
      complete(failure)
      return
    end
    if require("codediff.ui.lifecycle").get_panel_view(explorer.tabpage) ~= explorer then
      complete()
      return
    end
    explorer.base_revision, explorer.target_revision = resolved.original, resolved.modified
    fetch_status()
  end
  for side, revision in pairs(requested) do
    remaining = remaining + 1
    if revision == "WORKING" or revision:match("^:[0-3]$") then
      resolved[side] = revision
      settled()
    else
      git.resolve_revision(revision, explorer.git_root, function(err, hash)
        vim.schedule(function()
          resolved[side] = hash
          settled(err)
        end)
      end)
    end
  end
  settled()
end

-- Queue every refresh source through the controller installed on the explorer.
function M.refresh(explorer, done)
  if explorer and explorer._request_refresh then
    return explorer._request_refresh({ full = true }, done)
  end
  return M._refresh_once(explorer, done)
end

-- Rebuild the tree synchronously from the cached status_result. Used when only
-- group visibility changed (gs/gu): hiding or showing a group needs no new git
-- data, so we re-render immediately from the last known status instead of
-- waiting for an async git refresh. This keeps the tree — and navigation, which
-- reads it — consistent the moment visibility toggles.
function M.rebuild_from_cache(explorer)
  if not explorer or not explorer.winid or not vim.api.nvim_win_is_valid(explorer.winid) then
    return
  end
  local status_result = explorer.status_result
  if not status_result then
    -- No cached status yet; fall back to a full (async) refresh.
    M.refresh(explorer)
    return
  end
  local collapsed_state = collect_collapsed_state(explorer.tree)
  rebuild_tree(explorer, status_result, collapsed_state)
end

-- Get flat list of all files from tree (unstaged + staged)
-- Handles both list mode (flat) and tree mode (nested directories)
function M.get_all_files(tree)
  local files = {}

  -- Recursively collect files from a node and its children
  local function collect_files(parent_node)
    if not parent_node:has_children() then
      return
    end
    if not parent_node:is_expanded() then
      return
    end

    for _, child_id in ipairs(parent_node:get_child_ids()) do
      local node = tree:get_node(child_id)
      if node and node.data then
        if node.data.type == "directory" then
          -- Recurse into directory (tree mode)
          collect_files(node)
        elseif not node.data.type then
          -- It's a file (no type means file node)
          table.insert(files, {
            node = node,
            data = node.data,
          })
        end
      end
    end
  end

  local nodes = tree:get_nodes()
  for _, group_node in ipairs(nodes) do
    collect_files(group_node)
  end

  return files
end

return M
