local M = {}

function M.find_foldable_node(node, tree)
  if node:is_foldable() then
    return node
  end

  if node._parent_id then
    local parent = tree:get_node(node._parent_id)
    if parent and parent:is_foldable() then
      return parent
    end
  end
  return nil
end

function M.find_foldable_at_cursor(tree)
  local node = tree:get_node()
  if not node then
    return nil
  end
  return M.find_foldable_node(node, tree)
end

function M.get_root_node(tree)
  local node = tree:get_node()
  if not node then
    return
  end

  local function find_root(n)
    if not n._parent_id then
      return n
    end
    local parent = tree:get_node(n._parent_id)
    if parent then
      return find_root(parent)
    else
      return n
    end
  end
  return find_root(node)
end

-- Setup fold and diff-scroll keymaps on a tree buffer.
-- @param opts table { tree, keymaps, bufnr, tabpage }
function M.setup_fold_keymaps(opts)
  local tree = opts.tree
  local keymaps = opts.keymaps
  local bufnr = opts.bufnr
  local tabpage = opts.tabpage

  local function update_tree_view(node)
    tree:render()
    local winid = vim.fn.bufwinid(bufnr)
    if node._line and winid ~= -1 then
      vim.api.nvim_win_set_cursor(winid, { node._line, 0 })
    end
  end

  local function fold_open()
    local node = M.find_foldable_at_cursor(tree)
    if not node then
      return
    end
    node:expand()
    update_tree_view(node)
  end

  local function fold_open_recursive()
    local node = M.find_foldable_at_cursor(tree)
    if not node then
      return
    end
    node:expand_recursively()
    update_tree_view(node)
  end

  local function fold_close()
    local node = M.find_foldable_at_cursor(tree)
    if not node then
      return
    end
    node:collapse()
    update_tree_view(node)
  end

  local function fold_close_recursive()
    local node = M.find_foldable_at_cursor(tree)
    if not node then
      return
    end
    node:collapse_recursively()
    update_tree_view(node)
  end

  local function fold_toggle()
    local node = M.find_foldable_at_cursor(tree)
    if not node then
      return
    end
    if node:is_expanded() then
      node:collapse()
    else
      node:expand()
    end
    update_tree_view(node)
  end

  local function fold_toggle_recursive()
    local node = M.find_foldable_at_cursor(tree)
    if not node then
      return
    end
    if node:is_expanded() then
      node:collapse_recursively()
    else
      node:expand_recursively()
    end
    update_tree_view(node)
  end

  local function fold_open_all()
    local root = M.get_root_node(tree)
    if not root then
      return
    end
    root:expand_recursively()
    update_tree_view(root)
  end

  local function fold_close_all()
    local root = M.get_root_node(tree)
    if not root then
      return
    end
    root:collapse_recursively()
    update_tree_view(root)
  end

  local function scroll_diff(key)
    return function()
      local orig_win, mod_win = require("codediff.ui.lifecycle").get_windows(tabpage)
      local win = mod_win or orig_win
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_call(win, function()
          vim.cmd("normal! " .. vim.keycode(key))
        end)
      end
    end
  end

  local fold_bindings = {
    { key = "fold_open", fn = fold_open, desc = "Open fold" },
    { key = "fold_open_recursive", fn = fold_open_recursive, desc = "Open fold recursively" },
    { key = "fold_close", fn = fold_close, desc = "Close fold" },
    { key = "fold_close_recursive", fn = fold_close_recursive, desc = "Close fold recursively" },
    { key = "fold_toggle", fn = fold_toggle, desc = "Toggle fold" },
    { key = "fold_toggle_recursive", fn = fold_toggle_recursive, desc = "Toggle fold recursively" },
    { key = "fold_open_all", fn = fold_open_all, desc = "Open all folds" },
    { key = "fold_close_all", fn = fold_close_all, desc = "Close all folds" },
    { key = "scroll_down", fn = scroll_diff("<C-d>"), desc = "Scroll diff down" },
    { key = "scroll_up", fn = scroll_diff("<C-u>"), desc = "Scroll diff up" },
  }
  local map_options = { noremap = true, silent = true, nowait = true }
  local lifecycle = require("codediff.ui.lifecycle")
  for _, binding in ipairs(fold_bindings) do
    local key = keymaps[binding.key]
    if key then
      -- Tree panels are codediff-owned scratch buffers: their mappings cannot
      -- leak elsewhere, so they stay installed across tab switches.
      lifecycle.set_buf_keymap(tabpage, bufnr, "n", key, binding.fn, vim.tbl_extend("force", map_options, { desc = binding.desc }), { suspendable = false })
    end
  end
end

return M
