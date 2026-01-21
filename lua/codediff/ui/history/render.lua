-- UI rendering for file history panel (create split, tree, keymaps)
local M = {}

local Tree = require("nui.tree")
local Split = require("nui.split")
local config = require("codediff.config")
local git = require("codediff.core.git")
local nodes_module = require("codediff.ui.history.nodes")
local keymaps_module = require("codediff.ui.history.keymaps")

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

  -- Check if single file mode
  local is_single_file_mode = opts.file_path and opts.file_path ~= ""

  -- Calculate max widths for alignment
  local max_files = 0
  local max_insertions = 0
  local max_deletions = 0
  for _, commit in ipairs(commits) do
    if commit.files_changed > max_files then
      max_files = commit.files_changed
    end
    if commit.insertions > max_insertions then
      max_insertions = commit.insertions
    end
    if commit.deletions > max_deletions then
      max_deletions = commit.deletions
    end
  end
  local max_files_width = #tostring(max_files)
  local max_ins_width = #tostring(max_insertions)
  local max_del_width = #tostring(max_deletions)

  -- Build initial tree with commit nodes (files will be loaded on expand)
  local tree_nodes = {}
  local first_commit_node = nil -- Track first commit for auto-expand

  -- Build title based on context
  local title_text
  if opts.file_path and opts.file_path ~= "" then
    local filename = opts.file_path:match("([^/]+)$") or opts.file_path
    title_text = "File History: " .. filename .. " (" .. #commits .. ")"
  elseif opts.range and opts.range ~= "" then
    title_text = "Commit History: " .. opts.range .. " (" .. #commits .. ")"
  else
    title_text = "Commit History (" .. #commits .. ")"
  end

  -- Add title node
  tree_nodes[#tree_nodes + 1] = Tree.Node({
    id = "title",
    text = title_text,
    data = {
      type = "title",
      title = title_text,
    },
  })

  for _, commit in ipairs(commits) do
    -- Create placeholder commit node - files loaded on expand
    -- Use commit hash as unique ID to avoid duplicate ID errors when subjects match
    local commit_node = Tree.Node({
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
        ref_names = commit.ref_names,
        files_changed = commit.files_changed,
        insertions = commit.insertions,
        deletions = commit.deletions,
        file_count = commit.files_changed, -- Use files_changed as initial count
        git_root = git_root,
        files_loaded = false,
        -- File path at this commit (for single file mode with renames)
        -- Also used to detect single file mode in nodes.lua
        file_path = commit.file_path,
        -- Alignment info
        max_files_width = max_files_width,
        max_ins_width = max_ins_width,
        max_del_width = max_del_width,
      },
    })
    tree_nodes[#tree_nodes + 1] = commit_node
    -- Track first commit for auto-expand
    if not first_commit_node then
      first_commit_node = commit_node
    end
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

    -- Skip non-commit nodes (e.g., title node)
    if not data or data.type ~= "commit" then
      if callback then
        callback()
      end
      return
    end

    if data.files_loaded then
      -- Files already loaded, just expand
      commit_node:expand()
      tree:render()
      if callback then
        callback()
      end
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
        -- Create file nodes based on view_mode
        local history_config = config.options.history or {}
        local view_mode = history_config.view_mode or "list"

        local file_nodes
        if view_mode == "tree" then
          file_nodes = nodes_module.create_tree_file_nodes(files, data.hash, git_root)
        else
          file_nodes = nodes_module.create_list_file_nodes(files, data.hash, git_root)
        end

        -- Update node with children
        data.files_loaded = true
        data.file_count = #files

        -- NUI Tree doesn't have a direct "add children" API, so we need to rebuild
        -- For now, we'll use set_nodes on the commit node
        for _, file_node in ipairs(file_nodes) do
          tree:add_node(file_node, commit_node:get_id())
        end

        -- Auto-expand all directory nodes in tree mode
        if view_mode == "tree" then
          local function expand_directories(node_ids)
            for _, node_id in ipairs(node_ids) do
              local node = tree:get_node(node_id)
              if node and node.data and node.data.type == "directory" then
                node:expand()
                expand_directories(node:get_child_ids() or {})
              end
            end
          end
          expand_directories(commit_node:get_child_ids() or {})
        end

        commit_node:expand()
        tree:render()

        if callback then
          callback()
        end
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

    if not file_path or file_path == "" then
      vim.notify("[CodeDiff] No file path for selection", vim.log.levels.WARN)
      return
    end

    if not commit_hash or commit_hash == "" then
      vim.notify("[CodeDiff] No commit hash for selection", vim.log.levels.WARN)
      return
    end

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

  -- Setup keymaps
  keymaps_module.setup(history, {
    is_single_file_mode = is_single_file_mode,
    file_path = opts.file_path,
    git_root = git_root,
    load_commit_files = load_commit_files,
    navigate_next = M.navigate_next,
    navigate_prev = M.navigate_prev,
    nodes_module = nodes_module,
  })

  -- Auto-expand first commit and select first file
  if first_commit_node then
    vim.defer_fn(function()
      if is_single_file_mode then
        -- Single file mode: directly select the file at first commit
        -- Use file_path from commit data if available (handles renames), fallback to opts.file_path
        local file_path = first_commit_node.data.file_path or opts.file_path
        local file_data = {
          path = file_path,
          commit_hash = first_commit_node.data.hash,
          git_root = git_root,
        }
        history.on_file_select(file_data)
      else
        -- Multi-file mode: expand first commit and select first file
        load_commit_files(first_commit_node, function()
          if first_commit_node:has_children() then
            -- Find first file node (may need to traverse directories in tree mode)
            local function find_first_file(node_ids)
              for _, node_id in ipairs(node_ids) do
                local node = tree:get_node(node_id)
                if node and node.data then
                  if node.data.type == "file" then
                    return node
                  elseif node.data.type == "directory" then
                    -- Expand directory and search its children
                    node:expand()
                    local child_file = find_first_file(node:get_child_ids() or {})
                    if child_file then
                      return child_file
                    end
                  end
                end
              end
              return nil
            end

            local first_file = find_first_file(first_commit_node:get_child_ids() or {})
            if first_file and first_file.data then
              tree:render()
              history.on_file_select(first_file.data)
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
