-- UI rendering for explorer (create split, tree, keymaps)
local M = {}

local Tree = require("nui.tree")
local Split = require("nui.split")
local config = require("codediff.config")

-- Will be injected by init.lua
local nodes_module = nil
local tree_module = nil
local refresh_module = nil
local keymaps_module = nil
M._set_nodes_module = function(n)
  nodes_module = n
end
M._set_tree_module = function(t)
  tree_module = t
end
M._set_refresh_module = function(r)
  refresh_module = r
end
M._set_keymaps_module = function(k)
  keymaps_module = k
end

function M.create(status_result, git_root, tabpage, width, base_revision, target_revision, opts)
  opts = opts or {}
  local is_dir_mode = not git_root -- nil git_root signals directory comparison mode

  -- Get explorer position and size from config
  local explorer_config = config.options.explorer or {}
  local position = explorer_config.position or "left"
  local size
  local text_width -- Width for text rendering (always horizontal width)

  if position == "bottom" then
    size = explorer_config.height or 15
    -- For bottom position, use full window width for text
    text_width = vim.o.columns
  else
    -- Use provided width or config width or default to 40 columns
    size = width or explorer_config.width or 40
    text_width = size
  end

  -- Create split window for explorer
  local split = Split({
    relative = "editor",
    position = position,
    size = size,
    buf_options = {
      modifiable = false,
      readonly = true,
      filetype = "codediff-explorer",
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

  -- Mount split first to get bufnr
  split:mount()

  -- Track selected path and group for highlighting
  local selected_path = nil
  local selected_group = nil

  -- Create tree with buffer number
  local tree_data = tree_module.create_tree_data(status_result, git_root, base_revision, is_dir_mode)
  local tree = Tree({
    bufnr = split.bufnr,
    nodes = tree_data,
    prepare_node = function(node)
      -- Dynamically get current window width for responsive layout
      local current_width = text_width
      if split.winid and vim.api.nvim_win_is_valid(split.winid) then
        current_width = vim.api.nvim_win_get_width(split.winid)
      end
      return nodes_module.prepare_node(node, current_width, selected_path, selected_group)
    end,
  })

  -- Expand all groups by default before first render
  -- In tree mode, also expand all directories
  local function expand_nodes_recursive(nodes)
    for _, node in ipairs(nodes) do
      if node.data and (node.data.type == "group" or node.data.type == "directory") then
        node:expand()
        if node:has_children() then
          expand_nodes_recursive(node:get_child_ids())
        end
      end
    end
  end

  -- nui.tree get_child_ids returns IDs, need to get actual nodes
  for _, node in ipairs(tree_data) do
    if node.data and node.data.type == "group" then
      node:expand()
    end
  end

  -- For tree mode, expand directories after initial render when we have node IDs
  local explorer_config = config.options.explorer or {}
  if explorer_config.view_mode == "tree" then
    -- We need to expand directory nodes - they're children of group nodes
    local function expand_all_dirs(parent_node)
      if not parent_node:has_children() then
        return
      end
      for _, child_id in ipairs(parent_node:get_child_ids()) do
        local child = tree:get_node(child_id)
        if child and child.data and child.data.type == "directory" then
          child:expand()
          expand_all_dirs(child)
        end
      end
    end
    for _, node in ipairs(tree_data) do
      expand_all_dirs(node)
    end
  end

  -- Render tree
  tree:render()

  -- Create explorer object early so we can reference it in keymaps
  local explorer = {
    split = split,
    tree = tree,
    bufnr = split.bufnr,
    winid = split.winid,
    git_root = git_root,
    dir1 = opts.dir1,
    dir2 = opts.dir2,
    base_revision = base_revision,
    target_revision = target_revision,
    status_result = status_result, -- Store initial status result
    on_file_select = nil, -- Will be set below
    current_file_path = nil, -- Track currently selected file
    current_file_group = nil, -- Track currently selected file's group (staged/unstaged)
    is_hidden = false, -- Track visibility state
  }

  -- File selection callback - manages its own lifecycle
  local function on_file_select(file_data)
    local git = require("codediff.core.git")
    local view = require("codediff.ui.view")
    local lifecycle = require("codediff.ui.lifecycle")

    local file_path = file_data.path
    local old_path = file_data.old_path -- For renames: path in original revision
    local group = file_data.group or "unstaged"

    -- Dir mode: Compare files from dir1 vs dir2 (no git)
    if is_dir_mode then
      local original_path = explorer.dir1 .. "/" .. file_path
      local modified_path = explorer.dir2 .. "/" .. file_path

      -- Check if already displaying same file
      local session = lifecycle.get_session(tabpage)
      if session and session.original_path == original_path and session.modified_path == modified_path then
        return
      end

      vim.schedule(function()
        ---@type SessionConfig
        local session_config = {
          mode = "explorer",
          git_root = nil,
          original_path = original_path,
          modified_path = modified_path,
          original_revision = nil,
          modified_revision = nil,
        }
        view.update(tabpage, session_config, true)
      end)
      return
    end

    local abs_path = git_root .. "/" .. file_path

    -- Check if this exact diff is already being displayed
    -- Same file can have different diffs (staged vs HEAD, working vs staged)
    local session = lifecycle.get_session(tabpage)
    if session then
      local is_same_file = (session.modified_path == abs_path or (session.git_root and session.original_path == file_path))

      if is_same_file then
        -- Check if it's the same diff comparison
        local is_staged_diff = group == "staged"
        local current_is_staged = session.modified_revision == ":0"

        if is_staged_diff == current_is_staged then
          -- Same file AND same diff type, skip update
          return
        end
      end
    end

    if base_revision and target_revision and target_revision ~= "WORKING" then
      -- Two revision mode: Compare base vs target
      vim.schedule(function()
        ---@type SessionConfig
        local session_config = {
          mode = "explorer",
          git_root = git_root,
          original_path = old_path or file_path,
          modified_path = file_path,
          original_revision = base_revision,
          modified_revision = target_revision,
        }
        view.update(tabpage, session_config, true)
      end)
      return
    end

    -- Use base_revision if provided, otherwise default to HEAD
    local target_revision_single = base_revision or "HEAD"
    git.resolve_revision(target_revision_single, git_root, function(err_resolve, commit_hash)
      if err_resolve then
        vim.schedule(function()
          vim.notify(err_resolve, vim.log.levels.ERROR)
        end)
        return
      end

      if base_revision then
        -- Revision mode: Simple comparison of working tree vs base_revision
        vim.schedule(function()
          ---@type SessionConfig
          local session_config = {
            mode = "explorer",
            git_root = git_root,
            original_path = old_path or file_path,
            modified_path = abs_path,
            original_revision = commit_hash,
            modified_revision = nil,
          }
          view.update(tabpage, session_config, true)
        end)
      elseif group == "conflicts" then
        -- Merge conflict: Show incoming (:3) vs current (:2), both diffed against base (:1)
        -- Position controlled by config.diff.conflict_ours_position (absolute screen position)
        vim.schedule(function()
          -- Determine conflict buffer positions based on config
          -- conflict_ours_position controls where :2 (OURS) appears on screen
          local ours_position = config.options.diff.conflict_ours_position or "right"

          -- After conflict_window.lua's win_splitmove(rightbelow=false):
          -- - original_win is on LEFT
          -- - modified_win is on RIGHT
          local original_rev, modified_rev
          if ours_position == "right" then
            original_rev = ":3" -- THEIRS in original_win (LEFT)
            modified_rev = ":2" -- OURS in modified_win (RIGHT)
          else
            original_rev = ":2" -- OURS in original_win (LEFT)
            modified_rev = ":3" -- THEIRS in modified_win (RIGHT)
          end

          ---@type SessionConfig
          local session_config = {
            mode = "explorer",
            git_root = git_root,
            original_path = file_path,
            modified_path = file_path,
            original_revision = original_rev,
            modified_revision = modified_rev,
            conflict = true,
          }
          view.update(tabpage, session_config, true)
        end)
      elseif group == "staged" then
        -- Staged changes: Compare staged (:0) vs HEAD (both virtual)
        -- For renames: old_path in HEAD, new path in staging
        -- No pre-fetching needed, virtual files will load via BufReadCmd
        vim.schedule(function()
          ---@type SessionConfig
          local session_config = {
            mode = "explorer",
            git_root = git_root,
            original_path = old_path or file_path, -- Use old_path if rename
            modified_path = file_path, -- New path after rename
            original_revision = commit_hash,
            modified_revision = ":0",
          }
          view.update(tabpage, session_config, true)
        end)
      else
        -- Unstaged changes: Compare working tree vs staged (if exists) or HEAD
        -- Check if file is in staged list
        local is_staged = false
        -- Use current status_result from explorer object
        local current_status = explorer.status_result or status_result
        for _, staged_file in ipairs(current_status.staged) do
          if staged_file.path == file_path then
            is_staged = true
            break
          end
        end

        local original_revision = is_staged and ":0" or commit_hash

        -- No pre-fetching needed, buffers will load content
        vim.schedule(function()
          ---@type SessionConfig
          local session_config = {
            mode = "explorer",
            git_root = git_root,
            original_path = file_path,
            modified_path = abs_path,
            original_revision = original_revision,
            modified_revision = nil,
          }
          view.update(tabpage, session_config, true)
        end)
      end
    end)
  end

  -- Wrap on_file_select to track current file and group
  explorer.on_file_select = function(file_data)
    explorer.current_file_path = file_data.path
    explorer.current_file_group = file_data.group
    selected_path = file_data.path
    selected_group = file_data.group
    tree:render()
    on_file_select(file_data)
  end

  -- Setup keymaps (delegated to keymaps module)
  keymaps_module.setup(explorer)

  -- Find a file in the status lists, returns (file, group) or (nil, nil)
  local function find_file_in_status(path)
    if status_result.conflicts then
      for _, f in ipairs(status_result.conflicts) do
        if f.path == path then return f, "conflicts" end
      end
    end
    for _, f in ipairs(status_result.unstaged) do
      if f.path == path then return f, "unstaged" end
    end
    for _, f in ipairs(status_result.staged) do
      if f.path == path then return f, "staged" end
    end
    return nil, nil
  end

  -- Select initial file: prefer focus_file (current buffer) if changed, else first file
  local initial_file, initial_file_group
  local focus_file = opts and opts.focus_file
  if focus_file then
    initial_file, initial_file_group = find_file_in_status(focus_file)
  end
  if not initial_file then
    if status_result.conflicts and #status_result.conflicts > 0 then
      initial_file, initial_file_group = status_result.conflicts[1], "conflicts"
    elseif #status_result.unstaged > 0 then
      initial_file, initial_file_group = status_result.unstaged[1], "unstaged"
    elseif #status_result.staged > 0 then
      initial_file, initial_file_group = status_result.staged[1], "staged"
    end
  end

  if initial_file then
    vim.defer_fn(function()
      -- Scroll explorer to the selected file using tree:get_node(line) lookup
      if vim.api.nvim_win_is_valid(explorer.winid) and vim.api.nvim_buf_is_valid(explorer.bufnr) then
        local line_count = vim.api.nvim_buf_line_count(explorer.bufnr)
        for line = 1, line_count do
          local node = explorer.tree:get_node(line)
          if node and node.data and node.data.path == initial_file.path and node.data.group == initial_file_group then
            vim.api.nvim_win_set_cursor(explorer.winid, { line, 0 })
            break
          end
        end
      end

      explorer.on_file_select({
        path = initial_file.path,
        old_path = initial_file.old_path,
        status = initial_file.status,
        git_root = git_root,
        group = initial_file_group,
      })
    end, 100)
  end

  -- Setup auto-refresh
  refresh_module.setup_auto_refresh(explorer, tabpage)

  -- Re-render on window resize for dynamic width
  vim.api.nvim_create_autocmd("WinResized", {
    callback = function()
      -- Check if explorer window was resized
      local resized_wins = vim.v.event.windows or {}
      for _, win in ipairs(resized_wins) do
        if win == explorer.winid and vim.api.nvim_win_is_valid(win) then
          explorer.tree:render()
          break
        end
      end
    end,
  })

  return explorer
end

-- Setup auto-refresh on file save and focus

return M
