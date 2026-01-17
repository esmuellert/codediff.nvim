-- UI rendering for file history panel (create split, tree, keymaps)
local M = {}

local Tree = require("nui.tree")
local Split = require("nui.split")
local config = require("codediff.config")
local git = require("codediff.core.git")
local nodes_module = require("codediff.ui.history.nodes")

-- Create file history panel
-- commits: array of commit objects from git.get_commit_list
-- git_root: absolute path to git repository root
-- tabpage: tabpage handle
-- width: optional width override
-- opts: { range, path, ... } original options
function M.create(commits, git_root, tabpage, width, opts)
  opts = opts or {}

  -- Get history panel position and size from config (separate from explorer)
  local history_config = config.options.history or {}
  local position = history_config.position or "bottom"
  local size
  local text_width

  if position == "bottom" then
    size = history_config.height or 15
    text_width = vim.o.columns
  else
    size = width or history_config.width or 40
    text_width = size
  end

  -- Create split window for history panel
  local split = Split({
    relative = "editor",
    position = position,
    size = size,
    buf_options = {
      modifiable = false,
      readonly = true,
      filetype = "codediff-history",
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

  split:mount()

  -- Track selected commit and file
  local selected_commit = nil
  local selected_file = nil

  -- Build initial tree with commit nodes (files will be loaded on expand)
  local tree_nodes = {}
  for _, commit in ipairs(commits) do
    -- Create placeholder commit node - files loaded on expand
    -- Use commit hash as unique ID to avoid duplicate ID errors when subjects match
    tree_nodes[#tree_nodes + 1] = Tree.Node({
      id = "commit:" .. commit.hash,
      text = commit.subject,
      data = {
        type = "commit",
        hash = commit.hash,
        short_hash = commit.short_hash,
        author = commit.author,
        date = commit.date,
        date_relative = commit.date_relative,
        subject = commit.subject,
        file_count = nil, -- Unknown until expanded
        git_root = git_root,
        files_loaded = false,
      },
    })
  end

  local tree = Tree({
    bufnr = split.bufnr,
    nodes = tree_nodes,
    prepare_node = function(node)
      local current_width = text_width
      if split.winid and vim.api.nvim_win_is_valid(split.winid) then
        current_width = vim.api.nvim_win_get_width(split.winid)
      end
      return nodes_module.prepare_node(node, current_width, selected_commit, selected_file)
    end,
  })

  tree:render()

  -- Create history panel object
  local history = {
    split = split,
    tree = tree,
    bufnr = split.bufnr,
    winid = split.winid,
    git_root = git_root,
    commits = commits,
    opts = opts,
    on_file_select = nil,
    current_commit = nil,
    current_file = nil,
    is_hidden = false,
  }

  -- Load files for a commit and update its children
  local function load_commit_files(commit_node, callback)
    local data = commit_node.data
    if data.files_loaded then
      if callback then callback() end
      return
    end

    git.get_commit_files(data.hash, git_root, function(err, files)
      if err then
        vim.schedule(function()
          vim.notify("Failed to load commit files: " .. err, vim.log.levels.ERROR)
        end)
        return
      end

      vim.schedule(function()
        -- Create file nodes
        -- Use commit_hash:path as unique ID to avoid duplicates across commits
        local file_nodes = {}
        for _, file in ipairs(files) do
          local icon, icon_color = nodes_module.get_file_icon(file.path)
          local STATUS_SYMBOLS = {
            M = { symbol = "M", color = "DiagnosticWarn" },
            A = { symbol = "A", color = "DiagnosticOk" },
            D = { symbol = "D", color = "DiagnosticError" },
            R = { symbol = "R", color = "DiagnosticInfo" },
          }
          local status_info = STATUS_SYMBOLS[file.status] or { symbol = file.status, color = "Normal" }

          file_nodes[#file_nodes + 1] = Tree.Node({
            id = "file:" .. data.hash .. ":" .. file.path,
            text = file.path,
            data = {
              type = "file",
              path = file.path,
              old_path = file.old_path,
              status = file.status,
              icon = icon,
              icon_color = icon_color,
              status_symbol = status_info.symbol,
              status_color = status_info.color,
              git_root = git_root,
              commit_hash = data.hash,
            },
          })
        end

        -- Update node with children
        data.files_loaded = true
        data.file_count = #files

        -- NUI Tree doesn't have a direct "add children" API, so we need to rebuild
        -- For now, we'll use set_nodes on the commit node
        for _, file_node in ipairs(file_nodes) do
          tree:add_node(file_node, commit_node:get_id())
        end

        commit_node:expand()
        tree:render()

        if callback then callback() end
      end)
    end)
  end

  -- File selection callback
  local function on_file_select(file_data)
    local view = require("codediff.ui.view")
    local lifecycle = require("codediff.ui.lifecycle")

    local file_path = file_data.path
    local old_path = file_data.old_path
    local commit_hash = file_data.commit_hash

    -- Check if already displaying same file
    local session = lifecycle.get_session(tabpage)
    if session and session.original_revision == commit_hash .. "^" and session.modified_revision == commit_hash then
      if session.modified_path == file_path or session.original_path == file_path then
        return
      end
    end

    vim.schedule(function()
      ---@type SessionConfig
      local session_config = {
        mode = "history",
        git_root = git_root,
        original_path = old_path or file_path,
        modified_path = file_path,
        original_revision = commit_hash .. "^",
        modified_revision = commit_hash,
      }
      view.update(tabpage, session_config, true)
    end)
  end

  history.on_file_select = function(file_data)
    history.current_commit = file_data.commit_hash
    history.current_file = file_data.path
    selected_commit = file_data.commit_hash
    selected_file = file_data.path
    tree:render()
    on_file_select(file_data)
  end

  -- Keymaps
  local map_options = { noremap = true, silent = true, nowait = true }

  -- Toggle expand/collapse or select file
  if config.options.keymaps.explorer.select then
    vim.keymap.set("n", config.options.keymaps.explorer.select, function()
      local node = tree:get_node()
      if not node then
        return
      end

      if node.data and node.data.type == "commit" then
        if node:is_expanded() then
          node:collapse()
          tree:render()
        else
          -- Load files and expand
          load_commit_files(node)
        end
      elseif node.data and node.data.type == "file" then
        history.on_file_select(node.data)
      end
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Select/toggle entry" }))
  end

  -- Double-click support
  vim.keymap.set("n", "<2-LeftMouse>", function()
    local node = tree:get_node()
    if not node then
      return
    end
    if node.data and node.data.type == "file" then
      history.on_file_select(node.data)
    elseif node.data and node.data.type == "commit" then
      if node:is_expanded() then
        node:collapse()
        tree:render()
      else
        load_commit_files(node)
      end
    end
  end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Select file" }))

  -- Navigate to next file
  if config.options.keymaps.view.next_file then
    vim.keymap.set("n", config.options.keymaps.view.next_file, function()
      M.navigate_next(history)
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Next file" }))
  end

  -- Navigate to previous file
  if config.options.keymaps.view.prev_file then
    vim.keymap.set("n", config.options.keymaps.view.prev_file, function()
      M.navigate_prev(history)
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Previous file" }))
  end

  -- Auto-expand first commit and select first file
  if #tree_nodes > 0 then
    vim.defer_fn(function()
      local first_commit = tree_nodes[1]
      if first_commit then
        load_commit_files(first_commit, function()
          -- Select first file after loading
          if first_commit:has_children() then
            local child_ids = first_commit:get_child_ids()
            if #child_ids > 0 then
              local first_file = tree:get_node(child_ids[1])
              if first_file and first_file.data then
                history.on_file_select(first_file.data)
              end
            end
          end
        end)
      end
    end, 100)
  end

  -- Re-render on window resize
  vim.api.nvim_create_autocmd("WinResized", {
    callback = function()
      local resized_wins = vim.v.event.windows or {}
      for _, win in ipairs(resized_wins) do
        if win == history.winid and vim.api.nvim_win_is_valid(win) then
          history.tree:render()
          break
        end
      end
    end,
  })

  return history
end

-- Get all file nodes from tree (for navigation)
function M.get_all_files(tree)
  local files = {}

  local function collect_files(parent_node)
    if not parent_node:has_children() then
      return
    end
    if not parent_node:is_expanded() then
      return
    end

    for _, child_id in ipairs(parent_node:get_child_ids()) do
      local node = tree:get_node(child_id)
      if node and node.data and node.data.type == "file" then
        table.insert(files, {
          node = node,
          data = node.data,
        })
      end
    end
  end

  local nodes = tree:get_nodes()
  for _, commit_node in ipairs(nodes) do
    collect_files(commit_node)
  end

  return files
end

-- Navigate to next file
function M.navigate_next(history)
  local all_files = M.get_all_files(history.tree)
  if #all_files == 0 then
    vim.notify("No files in history", vim.log.levels.WARN)
    return
  end

  local current_commit = history.current_commit
  local current_file = history.current_file

  if not current_commit or not current_file then
    local first_file = all_files[1]
    history.on_file_select(first_file.data)
    return
  end

  -- Find current index
  local current_index = 0
  for i, file in ipairs(all_files) do
    if file.data.commit_hash == current_commit and file.data.path == current_file then
      current_index = i
      break
    end
  end

  local next_index = current_index % #all_files + 1
  local next_file = all_files[next_index]

  -- Update cursor position
  local current_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(history.winid) then
    vim.api.nvim_set_current_win(history.winid)
    vim.api.nvim_win_set_cursor(history.winid, { next_file.node._line or 1, 0 })
    vim.api.nvim_set_current_win(current_win)
  end

  history.on_file_select(next_file.data)
end

-- Navigate to previous file
function M.navigate_prev(history)
  local all_files = M.get_all_files(history.tree)
  if #all_files == 0 then
    vim.notify("No files in history", vim.log.levels.WARN)
    return
  end

  local current_commit = history.current_commit
  local current_file = history.current_file

  if not current_commit or not current_file then
    local last_file = all_files[#all_files]
    history.on_file_select(last_file.data)
    return
  end

  local current_index = 0
  for i, file in ipairs(all_files) do
    if file.data.commit_hash == current_commit and file.data.path == current_file then
      current_index = i
      break
    end
  end

  local prev_index = current_index - 2
  if prev_index < 0 then
    prev_index = #all_files + prev_index
  end
  prev_index = prev_index % #all_files + 1
  local prev_file = all_files[prev_index]

  local current_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(history.winid) then
    vim.api.nvim_set_current_win(history.winid)
    vim.api.nvim_win_set_cursor(history.winid, { prev_file.node._line or 1, 0 })
    vim.api.nvim_set_current_win(current_win)
  end

  history.on_file_select(prev_file.data)
end

-- Toggle visibility
function M.toggle_visibility(history)
  if not history or not history.split then
    return
  end

  if history.is_hidden then
    history.split:show()
    history.is_hidden = false
    history.winid = history.split.winid
    vim.schedule(function()
      vim.cmd("wincmd =")
    end)
  else
    history.split:hide()
    history.is_hidden = true
    vim.schedule(function()
      vim.cmd("wincmd =")
    end)
  end
end

return M
