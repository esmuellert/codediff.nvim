-- Tests for codediff.ui.lib modules: Line, Split, Tree

local Line = require("codediff.ui.lib.line")
local Split = require("codediff.ui.lib.split")
local Tree = require("codediff.ui.lib.tree")

-- ────────────────────────────────────────────────────────────────
-- Line
-- ────────────────────────────────────────────────────────────────
describe("Line", function()
  it("Line() constructor creates empty line", function()
    local line = Line()
    assert.is_not_nil(line)
    assert.same({}, line._segments)
  end)

  it("Line.new() alternative constructor", function()
    local line = Line.new()
    assert.is_not_nil(line)
    assert.same({}, line._segments)
  end)

  it("append() adds segments", function()
    local line = Line()
    line:append("hello")
    assert.equals(1, #line._segments)
    assert.equals("hello", line._segments[1].text)
  end)

  it("append() chaining", function()
    local line = Line()
    local ret = line:append("a"):append("b")
    assert.equals(line, ret)
    assert.equals(2, #line._segments)
  end)

  it("content() returns concatenated text", function()
    local line = Line()
    line:append("hello "):append("world")
    assert.equals("hello world", line:content())
  end)

  it("content() on empty line returns empty string", function()
    local line = Line()
    assert.equals("", line:content())
  end)

  it("segments preserve highlight groups", function()
    local line = Line()
    line:append("a", "HlA"):append("b", "HlB")
    assert.equals("HlA", line._segments[1].hl)
    assert.equals("HlB", line._segments[2].hl)
  end)

  it("_segments field contains correct data", function()
    local line = Line()
    line:append("x", "G1"):append("y")
    assert.same({ text = "x", hl = "G1" }, line._segments[1])
    assert.same({ text = "y", hl = nil }, line._segments[2])
  end)
end)

-- ────────────────────────────────────────────────────────────────
-- Split
-- ────────────────────────────────────────────────────────────────
describe("Split", function()
  local split

  after_each(function()
    if split then
      pcall(function()
        if split.winid and vim.api.nvim_win_is_valid(split.winid) then
          vim.api.nvim_win_hide(split.winid)
        end
      end)
      pcall(function()
        if split.bufnr and vim.api.nvim_buf_is_valid(split.bufnr) then
          vim.api.nvim_buf_delete(split.bufnr, { force = true })
        end
      end)
      split = nil
    end
  end)

  it("constructor stores options", function()
    split = Split({ position = "left", size = 30 })
    assert.is_not_nil(split)
    assert.equals("left", split._position)
    assert.equals(30, split._size)
  end)

  it("maps bottom to below", function()
    split = Split({ position = "bottom" })
    assert.equals("below", split._position)
  end)

  it("maps top to above", function()
    split = Split({ position = "top" })
    assert.equals("above", split._position)
  end)

  it("maps left to left", function()
    split = Split({ position = "left" })
    assert.equals("left", split._position)
  end)

  it("maps right to right", function()
    split = Split({ position = "right" })
    assert.equals("right", split._position)
  end)

  it("mount() creates buffer and window", function()
    split = Split({ position = "left", size = 20 })
    split:mount()
    assert.is_not_nil(split.bufnr)
    assert.is_not_nil(split.winid)
    assert.is_true(vim.api.nvim_buf_is_valid(split.bufnr))
    assert.is_true(vim.api.nvim_win_is_valid(split.winid))
  end)

  it("buffer options are applied after mount", function()
    split = Split({
      position = "left",
      size = 20,
      buf_options = { filetype = "testft" },
    })
    split:mount()
    assert.equals("testft", vim.bo[split.bufnr].filetype)
  end)

  it("window options are applied after mount", function()
    split = Split({
      position = "left",
      size = 20,
      win_options = { number = false },
    })
    split:mount()
    assert.is_false(vim.wo[split.winid].number)
  end)

  it("hide() closes window but keeps buffer valid", function()
    split = Split({ position = "left", size = 20 })
    split:mount()
    local bufnr = split.bufnr
    split:hide()
    assert.is_nil(split.winid)
    assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
  end)

  it("show() re-creates window with same buffer", function()
    split = Split({ position = "left", size = 20 })
    split:mount()
    local bufnr = split.bufnr
    split:hide()
    split:show()
    assert.is_not_nil(split.winid)
    assert.is_true(vim.api.nvim_win_is_valid(split.winid))
    assert.equals(bufnr, split.bufnr)
  end)

  it("show() is no-op if already visible", function()
    split = Split({ position = "left", size = 20 })
    split:mount()
    local winid = split.winid
    split:show()
    assert.equals(winid, split.winid)
  end)
end)

-- ────────────────────────────────────────────────────────────────
-- Tree
-- ────────────────────────────────────────────────────────────────
describe("Tree", function()
  local bufnr

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].modifiable = true
  end)

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    bufnr = nil
  end)

  -- Node creation ---------------------------------------------------

  it("Tree.Node({text, data}) creates node with auto ID", function()
    local node = Tree.Node({ text = "hello", data = { x = 1 } })
    assert.equals("hello", node.text)
    assert.same({ x = 1 }, node.data)
    assert.is_not_nil(node:get_id())
  end)

  it("Tree.Node({text, data, id}) uses explicit ID", function()
    local node = Tree.Node({ text = "n", data = {}, id = "my-id" })
    assert.equals("my-id", node:get_id())
  end)

  it("Tree.Node(props, children) links children", function()
    local c1 = Tree.Node({ text = "c1" })
    local c2 = Tree.Node({ text = "c2" })
    local parent = Tree.Node({ text = "p" }, { c1, c2 })
    assert.is_true(parent:has_children())
    assert.equals(2, #parent:get_child_ids())
  end)

  -- Node methods ----------------------------------------------------

  it("expand() / collapse() / is_expanded()", function()
    local node = Tree.Node({ text = "n" })
    assert.is_false(node:is_expanded())
    node:expand()
    assert.is_true(node:is_expanded())
    node:collapse()
    assert.is_false(node:is_expanded())
  end)

  it("has_children() returns false for leaf", function()
    local node = Tree.Node({ text = "leaf" })
    assert.is_false(node:has_children())
  end)

  it("get_child_ids() returns correct IDs", function()
    local c = Tree.Node({ text = "c", id = "child-1" })
    local p = Tree.Node({ text = "p" }, { c })
    assert.same({ "child-1" }, p:get_child_ids())
  end)

  it("get_depth() returns 0 before tree registration", function()
    local node = Tree.Node({ text = "n" })
    assert.equals(0, node:get_depth())
  end)

  it("get_depth() returns correct value after tree creation", function()
    local c = Tree.Node({ text = "c", id = "dc" })
    local p = Tree.Node({ text = "p", id = "dp" }, { c })
    local tree = Tree({ bufnr = bufnr, nodes = { p } })
    assert.equals(1, tree:get_node("dp"):get_depth())
    assert.equals(2, tree:get_node("dc"):get_depth())
  end)

  -- Tree creation ---------------------------------------------------

  it("Tree({bufnr, nodes}) creates tree", function()
    local n = Tree.Node({ text = "a", id = "a1" })
    local tree = Tree({ bufnr = bufnr, nodes = { n } })
    assert.is_not_nil(tree)
  end)

  it("get_nodes() returns root nodes", function()
    local n1 = Tree.Node({ text = "a", id = "r1" })
    local n2 = Tree.Node({ text = "b", id = "r2" })
    local tree = Tree({ bufnr = bufnr, nodes = { n1, n2 } })
    assert.equals(2, #tree:get_nodes())
  end)

  it("get_node(id) looks up by ID", function()
    local n = Tree.Node({ text = "x", id = "lookup" })
    local tree = Tree({ bufnr = bufnr, nodes = { n } })
    assert.equals("x", tree:get_node("lookup").text)
  end)

  -- Render ----------------------------------------------------------

  it("render() writes lines to buffer", function()
    local n1 = Tree.Node({ text = "line1", id = "l1" })
    local n2 = Tree.Node({ text = "line2", id = "l2" })
    local tree = Tree({ bufnr = bufnr, nodes = { n1, n2 } })
    tree:render()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({ "line1", "line2" }, lines)
  end)

  it("render() sets node._line on visible nodes", function()
    local n1 = Tree.Node({ text = "a", id = "v1" })
    local n2 = Tree.Node({ text = "b", id = "v2" })
    local tree = Tree({ bufnr = bufnr, nodes = { n1, n2 } })
    tree:render()
    assert.equals(1, n1._line)
    assert.equals(2, n2._line)
  end)

  it("get_node(line) looks up by line after render", function()
    local n = Tree.Node({ text = "x", id = "byline" })
    local tree = Tree({ bufnr = bufnr, nodes = { n } })
    tree:render()
    assert.equals("byline", tree:get_node(1):get_id())
  end)

  it("render() respects expansion state (collapsed children hidden)", function()
    local child = Tree.Node({ text = "child", id = "ch" })
    local parent = Tree.Node({ text = "parent", id = "pa" }, { child })
    local tree = Tree({ bufnr = bufnr, nodes = { parent } })

    -- collapsed: only parent visible
    tree:render()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({ "parent" }, lines)
    assert.is_nil(child._line)

    -- expanded: both visible
    parent:expand()
    tree:render()
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({ "parent", "child" }, lines)
    assert.equals(2, child._line)
  end)

  -- Mutation --------------------------------------------------------

  it("set_nodes() replaces all nodes", function()
    local n1 = Tree.Node({ text = "old", id = "o1" })
    local tree = Tree({ bufnr = bufnr, nodes = { n1 } })
    local n2 = Tree.Node({ text = "new", id = "n1" })
    tree:set_nodes({ n2 })
    assert.equals(1, #tree:get_nodes())
    assert.is_nil(tree:get_node("o1"))
    assert.is_not_nil(tree:get_node("n1"))
  end)

  it("add_node(node, parent_id) adds child", function()
    local parent = Tree.Node({ text = "p", id = "ap" })
    local tree = Tree({ bufnr = bufnr, nodes = { parent } })
    local child = Tree.Node({ text = "c", id = "ac" })
    tree:add_node(child, "ap")
    assert.is_true(parent:has_children())
    assert.is_not_nil(tree:get_node("ac"))
  end)

  it("add_node(node) adds root node", function()
    local tree = Tree({ bufnr = bufnr, nodes = {} })
    local n = Tree.Node({ text = "r", id = "ar" })
    tree:add_node(n)
    assert.equals(1, #tree:get_nodes())
  end)

  it("remove_node(id) removes node", function()
    local n = Tree.Node({ text = "bye", id = "rm" })
    local tree = Tree({ bufnr = bufnr, nodes = { n } })
    tree:remove_node("rm")
    assert.equals(0, #tree:get_nodes())
    assert.is_nil(tree:get_node("rm"))
  end)

  -- prepare_node callback ------------------------------------------

  it("prepare_node callback is called during render", function()
    local called_ids = {}
    local n = Tree.Node({ text = "cb", id = "pn" })
    local tree = Tree({
      bufnr = bufnr,
      nodes = { n },
      prepare_node = function(node)
        called_ids[#called_ids + 1] = node:get_id()
        local l = Line()
        l:append(node.text)
        return l
      end,
    })
    tree:render()
    assert.same({ "pn" }, called_ids)
  end)

  -- Highlights from Line segments -----------------------------------

  it("highlights from Line segments are applied as extmarks", function()
    local n = Tree.Node({ text = "hi", id = "hl" })
    local tree = Tree({
      bufnr = bufnr,
      nodes = { n },
      prepare_node = function(node)
        local l = Line()
        l:append("AB", "Comment")
        l:append("CD")
        return l
      end,
    })
    tree:render()
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })
    assert.is_true(#marks > 0)
    local mark = marks[1]
    local details = mark[4]
    assert.equals("Comment", details.hl_group)
  end)

  -- is_foldable -----------------------------------------------------

  it("is_foldable() returns true for group nodes", function()
    local node = Tree.Node({ text = "grp", data = { type = "group" } })
    assert.is_true(node:is_foldable())
  end)

  it("is_foldable() returns true for directory nodes", function()
    local node = Tree.Node({ text = "dir", data = { type = "directory" } })
    assert.is_true(node:is_foldable())
  end)

  it("is_foldable() returns false for commit nodes even with children", function()
    local child = Tree.Node({ text = "f", data = { type = "file" } })
    local node = Tree.Node({ text = "commit", data = { type = "commit" } }, { child })
    assert.is_true(node:has_children())
    assert.is_false(node:is_foldable())
  end)

  it("is_foldable() returns false for title nodes", function()
    local node = Tree.Node({ text = "title", data = { type = "title" } })
    assert.is_false(node:is_foldable())
  end)

  it("is_foldable() returns false for file nodes", function()
    local node = Tree.Node({ text = "file", data = { type = "file" } })
    assert.is_false(node:is_foldable())
  end)

  it("is_foldable() returns false for nodes without data.type", function()
    local node = Tree.Node({ text = "plain" })
    assert.is_false(node:is_foldable())
  end)

  -- expand_recursively / collapse_recursively -----------------------

  it("expand_recursively() expands foldable descendants only", function()
    local file = Tree.Node({ text = "f", id = "ef", data = { type = "file" } })
    local dir = Tree.Node({ text = "d", id = "ed", data = { type = "directory" } }, { file })
    local group = Tree.Node({ text = "g", id = "eg", data = { type = "group" } }, { dir })
    Tree({ bufnr = bufnr, nodes = { group } })

    group:expand_recursively()

    assert.is_true(group:is_expanded())
    assert.is_true(dir:is_expanded())
    assert.is_false(file:is_expanded())
  end)

  it("expand_recursively() on non-foldable node still propagates to foldable children", function()
    local file = Tree.Node({ text = "f", id = "hf", data = { type = "file" } })
    local dir = Tree.Node({ text = "d", id = "hd", data = { type = "directory" } }, { file })
    local commit = Tree.Node({ text = "c", id = "hc", data = { type = "commit" } }, { dir })
    Tree({ bufnr = bufnr, nodes = { commit } })

    commit:expand_recursively()

    assert.is_false(commit:is_expanded())
    assert.is_true(dir:is_expanded())
    assert.is_false(file:is_expanded())
  end)

  it("collapse_recursively() collapses all foldable descendants", function()
    local dir = Tree.Node({ text = "d", id = "cd", data = { type = "directory" } })
    local group = Tree.Node({ text = "g", id = "cg", data = { type = "group" } }, { dir })
    Tree({ bufnr = bufnr, nodes = { group } })

    group:expand()
    dir:expand()
    assert.is_true(group:is_expanded())
    assert.is_true(dir:is_expanded())

    group:collapse_recursively()

    assert.is_false(group:is_expanded())
    assert.is_false(dir:is_expanded())
  end)

  it("collapse_recursively() on non-foldable node propagates to foldable children", function()
    local dir = Tree.Node({ text = "d", id = "pd", data = { type = "directory" } })
    local commit = Tree.Node({ text = "c", id = "pc", data = { type = "commit" } }, { dir })
    Tree({ bufnr = bufnr, nodes = { commit } })

    commit:expand()
    dir:expand()

    commit:collapse_recursively()

    -- commit is not foldable so its _expanded stays as-is (set_expanded_recursively skips it)
    assert.is_true(commit:is_expanded())
    assert.is_false(dir:is_expanded())
  end)

  -- Interaction with render -----------------------------------------

  it("expand_recursively() + render() shows foldable children in buffer", function()
    local file = Tree.Node({ text = "file.lua", id = "rf", data = { type = "file" } })
    local dir = Tree.Node({ text = "src/", id = "rd", data = { type = "directory" } }, { file })
    local group = Tree.Node({ text = "Changes", id = "rg", data = { type = "group" } }, { dir })
    local tree = Tree({ bufnr = bufnr, nodes = { group } })

    group:expand_recursively()
    tree:render()

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({ "Changes", "src/", "file.lua" }, lines)
  end)

  it("collapse_recursively() + render() shows only root node", function()
    local file = Tree.Node({ text = "file.lua", id = "cf2", data = { type = "file" } })
    local dir = Tree.Node({ text = "src/", id = "cd2", data = { type = "directory" } }, { file })
    local group = Tree.Node({ text = "Changes", id = "cg2", data = { type = "group" } }, { dir })
    local tree = Tree({ bufnr = bufnr, nodes = { group } })

    group:expand_recursively()
    tree:render()
    assert.equals(3, #vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

    group:collapse_recursively()
    tree:render()

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({ "Changes" }, lines)
  end)
end)
