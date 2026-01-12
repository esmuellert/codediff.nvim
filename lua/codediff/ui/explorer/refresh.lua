-- Auto-refresh and refresh logic for explorer
local M = {}

local config = require("codediff.config")

-- Will be injected by init.lua
local tree_module = nil
M._set_tree_module = function(t)
  tree_module = t
end

-- Setup auto-refresh triggers for explorer
-- Returns a cleanup function that should be called when the explorer is destroyed
function M.setup_auto_refresh(explorer, tabpage)
  local refresh_timer = nil
  local debounce_ms = 500 -- Wait 500ms after last event
  local git_watcher = nil
  local group = vim.api.nvim_create_augroup("CodeDiffExplorerRefresh_" .. tabpage, { clear = true })

  local function cleanup()
    if refresh_timer then
      vim.fn.timer_stop(refresh_timer)
      refresh_timer = nil
    end
    if git_watcher then
      pcall(function()
        git_watcher:stop()
      end)
      -- On Windows, we must close the handle to release file locks
      pcall(function()
        git_watcher:close()
      end)
      git_watcher = nil
    end
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end

  -- Store cleanup function on explorer so it can be called from lifecycle cleanup
  explorer._cleanup_auto_refresh = cleanup

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

  -- Auto-refresh when explorer buffer is entered (user focuses explorer window)
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = explorer.bufnr,
    callback = function()
      if vim.api.nvim_tabpage_is_valid(tabpage) then
        debounced_refresh()
      end
    end,
  })

  -- Watch .git directory for changes (git mode only)
  -- Dir mode skips this - relies on BufEnter refresh only
  if explorer.git_root then
    local git = require("codediff.core.git")
    git.get_git_dir(explorer.git_root, function(err, git_dir)
      if err or not git_dir then
        return
      end

      -- Schedule to main thread to safely call Neovim APIs
      vim.schedule(function()
        -- Check if directory still exists (may be deleted in tests)
        if vim.fn.isdirectory(git_dir) ~= 1 then
          return
        end

        -- Check if tabpage is still valid (may be closed before async callback)
        if not vim.api.nvim_tabpage_is_valid(tabpage) then
          return
        end

        local uv = vim.uv or vim.loop
        git_watcher = uv.new_fs_event()
        if git_watcher then
          local ok = pcall(function()
            git_watcher:start(
              git_dir,
              {},
              vim.schedule_wrap(function(watch_err, filename, events)
                if watch_err then
                  return
                end
                -- Only refresh if this tabpage is current
                if vim.api.nvim_get_current_tabpage() == tabpage and vim.api.nvim_tabpage_is_valid(tabpage) and not explorer.is_hidden then
                  debounced_refresh()
                end
              end)
            )
          end)
          if not ok then
            -- Failed to start watcher, clean it up
            pcall(function()
              git_watcher:close()
            end)
            git_watcher = nil
          end
        end
      end)
    end)
  end

  -- Clean up on tab close
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    pattern = tostring(tabpage),
    callback = cleanup,
  })

  return cleanup
end

-- Collect collapsed state from tree (groups and directories that user manually collapsed)
local function collect_collapsed_state(tree)
  local collapsed = {}

  local function collect_from_node(node)
    if not node.data then
      return
    end
    local node_type = node.data.type
    if node_type == "group" or node_type == "directory" then
      -- Use path for directories, name for groups as unique key
      local key = node.data.path or node.data.name
      if key and not node:is_expanded() then
        collapsed[key] = true
      end
      -- Recurse into children
      if node:has_children() then
        for _, child_id in ipairs(node:get_child_ids()) do
          local child = tree:get_node(child_id)
          if child then
            collect_from_node(child)
          end
        end
      end
    end
  end

  local root_nodes = tree:get_nodes()
  for _, node in ipairs(root_nodes) do
    collect_from_node(node)
  end

  return collapsed
end

-- Restore collapsed state after tree rebuild
local function restore_collapsed_state(tree, collapsed, root_nodes)
  local function restore_node(node)
    if not node.data then
      return
    end
    local node_type = node.data.type
    if node_type == "group" or node_type == "directory" then
      local key = node.data.path or node.data.name
      if key and collapsed[key] then
        node:collapse()
      end
      -- Recurse into children
      if node:has_children() then
        for _, child_id in ipairs(node:get_child_ids()) do
          local child = tree:get_node(child_id)
          if child then
            restore_node(child)
          end
        end
      end
    end
  end

  for _, node in ipairs(root_nodes) do
    restore_node(node)
  end
end

-- Refresh explorer with updated git status
function M.refresh(explorer)
  local git = require("codediff.core.git")

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

  -- Collect collapsed state before async operation
  local collapsed_state = collect_collapsed_state(explorer.tree)

  local function process_result(err, status_result)
    vim.schedule(function()
      if err then
        vim.notify("Failed to refresh: " .. err, vim.log.levels.ERROR)
        return
      end

      -- Rebuild tree nodes using same structure as create_tree_data
      local root_nodes = tree_module.create_tree_data(status_result, explorer.git_root, explorer.base_revision, not explorer.git_root)

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

  -- Use appropriate function based on mode
  if not explorer.git_root then
    -- Dir mode: re-scan directories
    local dir_mod = require("codediff.core.dir")
    local diff = dir_mod.diff_directories(explorer.dir1, explorer.dir2)
    process_result(nil, diff.status_result)
  elseif explorer.base_revision and explorer.target_revision and explorer.target_revision ~= "WORKING" then
    git.get_diff_revisions(explorer.base_revision, explorer.target_revision, explorer.git_root, process_result)
  elseif explorer.base_revision then
    git.get_diff_revision(explorer.base_revision, explorer.git_root, process_result)
  else
    git.get_status(explorer.git_root, process_result)
  end
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
