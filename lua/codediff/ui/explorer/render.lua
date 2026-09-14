-- Explorer presentation. Repository data and file selection belong to the session.
local M = {}
local Tree = require("codediff.ui.lib.tree")
local Split = require("codediff.ui.lib.split")
local config = require("codediff.config")
local lifecycle = require("codediff.ui.lifecycle")
local nodes_module = require("codediff.ui.explorer.nodes")
local tree_module = require("codediff.ui.explorer.tree")
local keymaps_module = require("codediff.ui.explorer.keymaps")

local function expand_directories(tree, node)
  for _, child_id in ipairs(node:get_child_ids() or {}) do
    local child = tree:get_node(child_id)
    if child and child.data and child.data.type == "directory" then
      child:expand()
      expand_directories(tree, child)
    end
  end
end

function M.create(data, tabpage, width)
  local options = config.options.explorer or {}
  local position = options.position or "left"
  local size = position == "bottom" and (options.height or 15) or (width or options.width or 40)
  local text_width = position == "bottom" and vim.o.columns or size
  local split = Split({
    relative = "editor",
    position = position,
    size = size,
    buf_options = { modifiable = false, readonly = true, filetype = "codediff-explorer" },
    win_options = {
      number = false,
      relativenumber = false,
      cursorline = true,
      wrap = false,
      signcolumn = "no",
      foldcolumn = "0",
      statuscolumn = "",
      spell = false,
      winfixwidth = true,
      winfixheight = true,
    },
  })
  split:mount()
  pcall(vim.api.nvim_buf_set_name, split.bufnr, "CodeDiff Explorer [" .. tabpage .. "]")
  if options.hidden then
    split:hide()
  end

  local explorer = {
    data = data,
    tabpage = tabpage,
    split = split,
    bufnr = split.bufnr,
    winid = split.winid,
    is_hidden = options.hidden,
    visible_groups = vim.deepcopy(options.visible_groups or { staged = true, unstaged = true, conflicts = true }),
  }
  local tree_data = tree_module.create_tree_data(data.status_result, data.git_root, data.base_revision, not data.git_root, explorer.visible_groups)
  local tree = Tree({
    bufnr = split.bufnr,
    nodes = tree_data,
    prepare_node = function(node)
      local current_width = split.winid and vim.api.nvim_win_is_valid(split.winid) and vim.api.nvim_win_get_width(split.winid) or text_width
      local selected = explorer.data.current_selection or {}
      return nodes_module.prepare_node(node, current_width, selected.path, selected.group)
    end,
  })
  explorer.tree = tree
  for _, node in ipairs(tree_data) do
    if node.data and node.data.type == "group" then
      node:expand()
    end
    if options.view_mode == "tree" then
      expand_directories(tree, node)
    end
  end
  tree:render()

  explorer.on_data = function(value, changes)
    explorer.data = value
    if not vim.api.nvim_buf_is_valid(explorer.bufnr) then
      return
    end
    if changes.list then
      tree_module.rebuild(explorer)
    elseif changes.selection and not explorer.is_hidden then
      tree:render()
    end
  end
  explorer.on_file_select = function(file, opts)
    return require("codediff.ui.refresh").select(tabpage, file, opts)
  end
  keymaps_module.setup(explorer)

  if options.auto_open_on_cursor then
    local function open_under_cursor()
      if not vim.api.nvim_buf_is_valid(split.bufnr) then
        return
      end
      local node = tree:get_node()
      if not node or not node.data or node.data.type == "group" or node.data.type == "directory" then
        return
      end
      local selected = explorer.data.current_selection or {}
      if selected.path ~= node.data.path or selected.group ~= node.data.group then
        explorer.on_file_select(node.data)
      end
    end
    for _, key in ipairs({ "j", "k", "<Down>", "<Up>" }) do
      lifecycle.set_buf_keymap(tabpage, split.bufnr, "n", key, function()
        vim.cmd("normal! " .. (key == "<Down>" and "j" or key == "<Up>" and "k" or key))
        open_under_cursor()
      end, { silent = true, desc = "codediff: move and auto-open file" }, { suspendable = false })
    end
  end

  local files = tree_module.get_all_files(tree)
  local initial_file = files[1]
  if data.focus_file then
    for _, file in ipairs(files) do
      if file.data.path == data.focus_file then
        initial_file = file
        break
      end
    end
  end
  if initial_file then
    vim.schedule(function()
      if lifecycle.get_panel_view(tabpage) ~= explorer then
        return
      end
      if explorer.winid and vim.api.nvim_win_is_valid(explorer.winid) and initial_file.node._line then
        vim.api.nvim_win_set_cursor(explorer.winid, { initial_file.node._line, 0 })
      end
      explorer.on_file_select(initial_file.data)
    end)
  end

  vim.api.nvim_create_autocmd("WinResized", {
    callback = function()
      for _, win in ipairs(vim.v.event.windows or {}) do
        if win == explorer.winid and vim.api.nvim_win_is_valid(win) then
          tree:render()
          break
        end
      end
    end,
  })
  return explorer
end

return M
