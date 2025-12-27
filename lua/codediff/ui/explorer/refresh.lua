-- Auto-refresh and refresh logic for explorer
local M = {}

local config = require("codediff.config")

-- Will be injected by init.lua
local tree_module = nil
M._set_tree_module = function(t) tree_module = t end

-- Setup auto-refresh on file save
function M.setup_auto_refresh(explorer, tabpage)
  -- Dir mode: no auto-refresh (static snapshot)
  if explorer.mode == "dir" then
    return
  end

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
  local group = vim.api.nvim_create_augroup('CodeDiffExplorerRefresh_' .. tabpage, { clear = true })
  
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
  -- Dir mode: no refresh (static snapshot)
  if explorer.mode == "dir" then
    return
  end

  local git = require('codediff.core.git')
  
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
      local root_nodes = tree_module.create_tree_data(status_result, explorer.git_root, explorer.base_revision, explorer.mode)
      
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
          if not parent_node:has_children() then return end
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
-- Handles both list mode (flat) and tree mode (nested directories)
function M.get_all_files(tree)
  local files = {}
  
  -- Recursively collect files from a node and its children
  local function collect_files(parent_node)
    if not parent_node:has_children() then return end
    if not parent_node:is_expanded() then return end
    
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
