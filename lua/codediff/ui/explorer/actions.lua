-- User actions for explorer (navigation, toggle, etc.)
local M = {}

local config = require("codediff.config")
local git = require("codediff.core.git")

-- Will be injected by init.lua
local refresh_module = nil
M._set_refresh_module = function(r)
  refresh_module = r
end

-- Find line number for a file node by scanning the tree
-- Returns the line number or nil if not found
local function find_node_line(explorer, path, group)
  local line_count = vim.api.nvim_buf_line_count(explorer.bufnr)
  for line = 1, line_count do
    local node = explorer.tree:get_node(line)
    if node and node.data and node.data.path == path and node.data.group == group then
      return line
    end
  end
  return nil
end

-- Navigate to next file in explorer
function M.navigate_next(explorer)
  local all_files = refresh_module.get_all_files(explorer.tree)
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
    local line = find_node_line(explorer, next_file.data.path, next_file.data.group)
    if line then
      vim.api.nvim_set_current_win(explorer.winid)
      vim.api.nvim_win_set_cursor(explorer.winid, { line, 0 })
      vim.api.nvim_set_current_win(current_win)
    end
  end

  -- Trigger file select
  explorer.on_file_select(next_file.data)
end

-- Navigate to previous file in explorer
function M.navigate_prev(explorer)
  local all_files = refresh_module.get_all_files(explorer.tree)
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
    local line = find_node_line(explorer, prev_file.data.path, prev_file.data.group)
    if line then
      vim.api.nvim_set_current_win(explorer.winid)
      vim.api.nvim_win_set_cursor(explorer.winid, { line, 0 })
      vim.api.nvim_set_current_win(current_win)
    end
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
        vim.cmd("wincmd =")
      end
    end)
  else
    explorer.split:hide()
    explorer.is_hidden = true

    -- Equalize diff windows after hiding explorer
    vim.schedule(function()
      vim.cmd("wincmd =")
    end)
  end
end

-- Toggle view mode between 'list' and 'tree'
function M.toggle_view_mode(explorer)
  if not explorer then
    return
  end

  local explorer_config = config.options.explorer or {}
  local current_mode = explorer_config.view_mode or "list"
  local new_mode = (current_mode == "list") and "tree" or "list"

  -- Update config
  config.options.explorer.view_mode = new_mode

  -- Refresh to rebuild tree with new mode
  refresh_module.refresh(explorer)

  vim.notify("Explorer view: " .. new_mode, vim.log.levels.INFO)
end

-- Stage/unstage a file by path and group (lower-level function)
-- This can be called from anywhere with explicit path and group
-- @param git_root: git repository root
-- @param file_path: relative path to file
-- @param group: "staged", "unstaged", or "conflicts"
-- @return boolean: true if operation was initiated
function M.toggle_stage_file(git_root, file_path, group)
  if not git_root then
    vim.notify("Stage/unstage only available in git mode", vim.log.levels.WARN)
    return false
  end

  if not file_path or not group then
    return false
  end

  -- Guard: only stageable groups
  if group ~= "staged" and group ~= "unstaged" and group ~= "conflicts" then
    return false
  end

  if group == "staged" then
    -- Unstage file
    git.unstage_file(git_root, file_path, function(err)
      if err then
        vim.schedule(function()
          vim.notify(err, vim.log.levels.ERROR)
        end)
      end
    end)
  elseif group == "unstaged" then
    -- Stage file
    git.stage_file(git_root, file_path, function(err)
      if err then
        vim.schedule(function()
          vim.notify(err, vim.log.levels.ERROR)
        end)
      end
    end)
  elseif group == "conflicts" then
    -- Stage conflict file (marks as resolved)
    git.stage_file(git_root, file_path, function(err)
      if err then
        vim.schedule(function()
          vim.notify(err, vim.log.levels.ERROR)
        end)
      end
    end)
  end

  return true
end

-- Stage/unstage all files under a directory
-- @param git_root: git repository root
-- @param dir_path: relative directory path
-- @param group: "staged" or "unstaged"
local function toggle_stage_directory(git_root, dir_path, group)
  if group == "staged" then
    -- Unstage directory
    git.unstage_file(git_root, dir_path, function(err)
      if err then
        vim.schedule(function()
          vim.notify(err, vim.log.levels.ERROR)
        end)
      end
    end)
  elseif group == "unstaged" then
    -- Stage directory
    git.stage_file(git_root, dir_path, function(err)
      if err then
        vim.schedule(function()
          vim.notify(err, vim.log.levels.ERROR)
        end)
      end
    end)
  end
end

-- Stage/unstage toggle for the selected entry in explorer (file or directory)
function M.toggle_stage_entry(explorer, tree)
  if not explorer or not explorer.git_root then
    vim.notify("Stage/unstage only available in git mode", vim.log.levels.WARN)
    return
  end

  local node = tree:get_node()
  if not node or not node.data or node.data.type == "group" then
    return
  end

  local entry_type = node.data.type
  local group = node.data.group

  if entry_type == "directory" then
    -- Directory uses dir_path, not path
    local dir_path = node.data.dir_path
    if dir_path then
      toggle_stage_directory(explorer.git_root, dir_path, group)
    end
  else
    -- File uses path
    local path = node.data.path
    if path then
      M.toggle_stage_file(explorer.git_root, path, group)
    end
  end
end

-- Stage all files
function M.stage_all(explorer)
  if not explorer or not explorer.git_root then
    vim.notify("Stage all only available in git mode", vim.log.levels.WARN)
    return
  end

  git.stage_all(explorer.git_root, function(err)
    if err then
      vim.schedule(function()
        vim.notify(err, vim.log.levels.ERROR)
      end)
    end
  end)
end

-- Unstage all files
function M.unstage_all(explorer)
  if not explorer or not explorer.git_root then
    vim.notify("Unstage all only available in git mode", vim.log.levels.WARN)
    return
  end

  git.unstage_all(explorer.git_root, function(err)
    if err then
      vim.schedule(function()
        vim.notify(err, vim.log.levels.ERROR)
      end)
    end
  end)
end

-- Restore/discard changes to the selected file or directory
function M.restore_entry(explorer, tree)
  if not explorer or not explorer.git_root then
    vim.notify("Restore only available in git mode", vim.log.levels.WARN)
    return
  end

  local node = tree:get_node()
  if not node or not node.data or node.data.type == "group" then
    return
  end

  local entry_type = node.data.type
  local is_directory = entry_type == "directory"
  local entry_path = is_directory and node.data.dir_path or node.data.path
  local group = node.data.group
  local status = node.data.status

  if not entry_path then
    return
  end

  -- Only restore unstaged changes (working tree changes)
  if group ~= "unstaged" then
    vim.notify("Can only restore unstaged changes", vim.log.levels.WARN)
    return
  end

  -- For directories, we don't have a single status, so assume mixed
  -- For files, check if untracked
  local is_untracked = not is_directory and status == "??"
  local display_name = entry_path .. (is_directory and "/" or "")

  -- Two-line confirmation prompt
  local action_word = is_directory and "Discard all changes in " or (is_untracked and "Delete " or "Discard changes to ")
  vim.api.nvim_echo({
    { action_word, "WarningMsg" },
    { display_name, "WarningMsg" },
    { "?\n", "WarningMsg" },
    { "(D)", "WarningMsg" },
    { is_untracked and "elete, " or "iscard, ", "WarningMsg" },
    { "[C]", "WarningMsg" },
    { "ancel: ", "WarningMsg" },
  }, false, {})

  local char = vim.fn.getcharstr():lower()

  if char == "d" then
    if is_untracked then
      -- Delete untracked file (directories with untracked files need -fd flag)
      git.delete_untracked(explorer.git_root, entry_path, function(err)
        if err then
          vim.schedule(function()
            vim.notify(err, vim.log.levels.ERROR)
          end)
        end
      end)
    else
      -- Restore tracked file/directory
      git.restore_file(explorer.git_root, entry_path, function(err)
        if err then
          vim.schedule(function()
            vim.notify(err, vim.log.levels.ERROR)
          end)
        end
      end)
    end
  end
  vim.cmd("echo ''") -- Clear prompt
end

return M
