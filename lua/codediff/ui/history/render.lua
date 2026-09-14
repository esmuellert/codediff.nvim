-- History presentation. Commit data is supplied by the session refresh controller.
local M = {}
local Tree = require("codediff.ui.lib.tree")
local Split = require("codediff.ui.lib.split")
local config = require("codediff.config")
local nodes_module = require("codediff.ui.history.nodes")
local keymaps_module = require("codediff.ui.history.keymaps")
local layout = require("codediff.ui.layout")

function M.build_tree_nodes(commits, git_root, opts)
  opts = opts or {}
  local max_files, max_insertions, max_deletions = 0, 0, 0
  for _, commit in ipairs(commits) do
    max_files = math.max(max_files, commit.files_changed)
    max_insertions = math.max(max_insertions, commit.insertions)
    max_deletions = math.max(max_deletions, commit.deletions)
  end
  local title
  if opts.file_path and opts.file_path ~= "" then
    title = "File History: " .. (opts.file_path:match("([^/]+)$") or opts.file_path) .. " (" .. #commits .. ")"
  elseif opts.range and opts.range ~= "" then
    title = "Commit History: " .. opts.range .. " (" .. #commits .. ")"
  else
    title = "Commit History (" .. #commits .. ")"
  end
  if opts.base_revision then
    title = title .. " [base: " .. opts.base_revision .. "]"
  end
  local result = { Tree.Node({ id = "title", text = title, data = { type = "title", title = title } }) }
  for _, commit in ipairs(commits) do
    result[#result + 1] = Tree.Node({
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
        file_count = commit.files_changed,
        git_root = git_root,
        files_loaded = false,
        file_path = commit.file_path,
        max_files_width = #tostring(max_files),
        max_ins_width = #tostring(max_insertions),
        max_del_width = #tostring(max_deletions),
      },
    })
  end
  return result
end

local function expand_directories(tree, ids)
  for _, id in ipairs(ids) do
    local node = tree:get_node(id)
    if node and node.data and node.data.type == "directory" then
      node:expand()
      expand_directories(tree, node:get_child_ids() or {})
    end
  end
end

local function find_first_file(tree, ids)
  for _, id in ipairs(ids) do
    local node = tree:get_node(id)
    if node and node.data then
      if node.data.type == "file" then
        return node
      elseif node.data.type == "directory" then
        node:expand()
        local first = find_first_file(tree, node:get_child_ids() or {})
        if first then
          return first
        end
      end
    end
  end
end

-- Turn cached commit files into children; this function never fetches data.
local function render_files(history, node)
  local files = history.data.files[node.data.hash]
  if not files then
    return
  end
  local tree = history.tree
  for _, id in ipairs(node:get_child_ids() or {}) do
    tree:remove_node(id)
  end
  local tree_mode = config.options.history.view_mode == "tree"
  local create = tree_mode and nodes_module.create_tree_file_nodes or nodes_module.create_list_file_nodes
  for _, child in ipairs(create(files, node.data.hash, history.data.git_root)) do
    tree:add_node(child, node:get_id())
  end
  node.data.files_loaded, node.data.file_count = true, #files
  if tree_mode then
    expand_directories(tree, node:get_child_ids() or {})
  end
end

function M.create(data, tabpage, width)
  local opts = data.opts
  local options = config.options.history or {}
  local position = options.position or "bottom"
  local size = position == "bottom" and (options.height or 15) or (width or options.width or 40)
  local text_width = position == "bottom" and vim.o.columns or size
  local split = Split({
    relative = "editor",
    position = position,
    size = size,
    buf_options = { modifiable = false, readonly = true, filetype = "codediff-history" },
    win_options = { number = false, relativenumber = false, cursorline = true, wrap = false, signcolumn = "no", foldcolumn = "0", statuscolumn = "", spell = false },
  })
  split:mount()
  pcall(vim.api.nvim_buf_set_name, split.bufnr, "CodeDiff History [" .. tabpage .. "]")
  local history = {
    data = data,
    tabpage = tabpage,
    split = split,
    bufnr = split.bufnr,
    winid = split.winid,
    is_hidden = false,
    is_single_file_mode = opts.file_path and opts.file_path ~= "",
  }
  local tree = Tree({
    bufnr = split.bufnr,
    nodes = M.build_tree_nodes(data.commits, data.git_root, opts),
    prepare_node = function(node)
      local current_width = split.winid and vim.api.nvim_win_is_valid(split.winid) and vim.api.nvim_win_get_width(split.winid) or text_width
      local selected = history.data.current_selection or {}
      return nodes_module.prepare_node(node, current_width, selected.commit_hash, selected.path, history.is_single_file_mode)
    end,
  })
  history.tree = tree
  tree:render()

  history.on_data = function(value, changes)
    history.data = value
    if not vim.api.nvim_buf_is_valid(history.bufnr) then
      return
    end
    if changes.list then
      local expanded = {}
      for _, node in ipairs(tree:get_nodes()) do
        if node.data and node.data.type == "commit" and node:is_expanded() then
          expanded[node.data.hash] = true
        end
      end
      tree:set_nodes(M.build_tree_nodes(value.commits, value.git_root, value.opts))
      for _, node in ipairs(tree:get_nodes()) do
        if node.data and node.data.type == "commit" and expanded[node.data.hash] then
          node:expand()
          render_files(history, node)
        end
      end
    elseif changes.files then
      local node = tree:get_node("commit:" .. changes.files)
      if node then
        render_files(history, node)
      end
    end
    if not history.is_hidden then
      tree:render()
      if changes.list and history.winid and vim.api.nvim_win_is_valid(history.winid) then
        local selected = value.current_commit and tree:get_node("commit:" .. value.current_commit)
        if selected and selected._line then
          vim.api.nvim_win_set_cursor(history.winid, { selected._line, 0 })
        end
      end
    end
  end
  history.on_file_select = function(file, selection_opts)
    return require("codediff.ui.refresh").select(tabpage, file, selection_opts)
  end
  history.load_commit_files = function(node, done)
    if not node.data or node.data.type ~= "commit" then
      if done then
        done()
      end
      return
    end
    node:expand()
    if history.data.files[node.data.hash] then
      render_files(history, node)
      tree:render()
      if done then
        done()
      end
    else
      require("codediff.ui.refresh").load_commit_files(tabpage, node.data.hash, done)
    end
  end
  keymaps_module.setup(history, {
    is_single_file_mode = history.is_single_file_mode,
    file_path = opts.file_path,
    git_root = data.git_root,
    tabpage = tabpage,
    load_commit_files = history.load_commit_files,
  })

  local first = data.commits[1]
  if first then
    vim.schedule(function()
      if require("codediff.ui.lifecycle").get_panel_view(tabpage) ~= history then
        return
      end
      if history.is_single_file_mode then
        history.on_file_select({ path = first.file_path or opts.file_path, commit_hash = first.hash, git_root = data.git_root })
      else
        local node = tree:get_node("commit:" .. first.hash)
        history.load_commit_files(node, function(err)
          local current = tree:get_node("commit:" .. first.hash)
          local file = not err and current and find_first_file(tree, current:get_child_ids() or {})
          if file then
            tree:render()
            history.on_file_select(file.data)
          end
        end)
      end
    end)
  end
  vim.api.nvim_create_autocmd("WinResized", {
    callback = function()
      for _, win in ipairs(vim.v.event.windows or {}) do
        if win == history.winid and vim.api.nvim_win_is_valid(win) then
          tree:render()
          break
        end
      end
    end,
  })
  return history
end

function M.get_all_files(tree)
  local files = {}
  for _, commit in ipairs(tree:get_nodes()) do
    if commit:is_expanded() then
      for _, id in ipairs(commit:get_child_ids() or {}) do
        local node = tree:get_node(id)
        if node and node.data and node.data.type == "file" then
          files[#files + 1] = { node = node, data = node.data }
        end
      end
    end
  end
  return files
end

function M.get_all_commits(tree)
  local commits = {}
  for _, node in ipairs(tree:get_nodes()) do
    if node.data and node.data.type == "commit" then
      commits[#commits + 1] = { node = node, data = node.data }
    end
  end
  return commits
end

local function navigate(history, direction, commits)
  local entries = commits and M.get_all_commits(history.tree) or M.get_all_files(history.tree)
  local kind = commits and "commit" or "file"
  if #entries == 0 then
    vim.notify(commits and "No commits in history" or "No files in history", vim.log.levels.WARN)
    return
  end
  local data = history.data
  local index = 0
  for i, entry in ipairs(entries) do
    if commits and entry.data.hash == data.current_commit or not commits and entry.data.commit_hash == data.current_commit and entry.data.path == data.current_file then
      index = i
      break
    end
  end
  local selected = data.current_commit and (commits or data.current_file)
  if selected and not config.options.diff.cycle_next_file and (direction > 0 and index >= #entries or direction < 0 and index <= 1) then
    local message = direction > 0 and string.format("Last %s (%d of %d)", kind, #entries, #entries) or string.format("First %s (1 of %d)", kind, #entries)
    vim.api.nvim_echo({ { message, "WarningMsg" } }, false, {})
    return
  end
  if not commits then
    vim.api.nvim_echo({}, false, {})
  end
  local next_index = selected and ((index - 1 + direction) % #entries + 1) or (direction > 0 and 1 or #entries)
  local entry = entries[next_index]
  if selected and history.winid and vim.api.nvim_win_is_valid(history.winid) then
    vim.api.nvim_win_set_cursor(history.winid, { entry.node._line or 1, 0 })
  end
  local file = entry.data
  if commits then
    file = { path = entry.data.file_path or data.opts.file_path, commit_hash = entry.data.hash, git_root = data.git_root }
  end
  history.on_file_select(file)
end

function M.navigate_next(history)
  navigate(history, 1, false)
end

function M.navigate_prev(history)
  navigate(history, -1, false)
end

function M.navigate_next_commit(history)
  navigate(history, 1, true)
end

function M.navigate_prev_commit(history)
  navigate(history, -1, true)
end

function M.toggle_visibility(history)
  if not history or not history.split then
    return
  end
  if history.is_hidden then
    history.split:show()
    history.winid = history.split.winid
  else
    history.split:hide()
  end
  history.is_hidden = not history.is_hidden
  vim.schedule(function()
    layout.arrange(history.tabpage)
  end)
end

return M
