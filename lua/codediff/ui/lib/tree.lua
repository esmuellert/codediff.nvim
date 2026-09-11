-- Drop-in replacement for nui.tree
-- Provides hierarchical tree data structure with buffer rendering

local Tree = {}
Tree.__index = Tree

local Node = {}
Node.__index = Node

local _id_counter = 0

local function next_id()
  _id_counter = _id_counter + 1
  return tostring(_id_counter)
end

--- Create a tree node (matches NuiTree.Node API)
---@param props table { text?: string, data?: table, id?: string }
---@param children? table[] Array of child Node objects
---@return table Node
function Tree.Node(props, children)
  local node = setmetatable({}, Node)
  node._id = props.id or next_id()
  node.text = props.text or ""
  node.data = props.data or {}
  node._expanded = false
  node._depth = 0
  node._line = nil
  node._parent_id = nil
  node._children = {}

  if children then
    for _, child in ipairs(children) do
      node._children[#node._children + 1] = child
      child._parent_id = node._id
    end
  end

  return node
end

-- Node methods

local function set_expanded_recursively(node, expanded)
  if node:is_foldable() then
    node._expanded = expanded
  end
  for _, child in ipairs(node._children) do
    set_expanded_recursively(child, expanded)
  end
end

function Node:get_id()
  return self._id
end

function Node:is_expanded()
  return self._expanded
end

function Node:is_foldable()
  return self.data and (self.data.type == "group" or self.data.type == "directory") or false
end

function Node:expand()
  self._expanded = true
end

function Node:expand_recursively()
  set_expanded_recursively(self, true)
end

function Node:collapse()
  self._expanded = false
end

function Node:collapse_recursively()
  set_expanded_recursively(self, false)
end

function Node:has_children()
  return #self._children > 0
end

function Node:get_child_ids()
  local ids = {}
  for _, child in ipairs(self._children) do
    ids[#ids + 1] = child._id
  end
  return ids
end

function Node:get_depth()
  return self._depth
end

-- Tree constructor

function Tree.new(opts)
  local self = setmetatable({}, Tree)
  self._bufnr = opts.bufnr
  self._prepare_node = opts.prepare_node
  self._nodes = opts.nodes or {}
  self._nodes_by_id = {}
  self._line_to_node = {}
  self._ns_id = vim.api.nvim_create_namespace("")

  self:_register_nodes(self._nodes, 1)
  return self
end

-- Allow Tree({...}) constructor syntax
setmetatable(Tree, {
  __call = function(cls, opts)
    return cls.new(opts)
  end,
})

--- Register nodes recursively in the flat lookup table and set depths
function Tree:_register_nodes(nodes, depth)
  for _, node in ipairs(nodes) do
    node._depth = depth
    self._nodes_by_id[node._id] = node
    if #node._children > 0 then
      self:_register_nodes(node._children, depth + 1)
    end
  end
end

--- Unregister a node and all its descendants from the lookup table
function Tree:_unregister_node(node)
  self._nodes_by_id[node._id] = nil
  for _, child in ipairs(node._children) do
    self:_unregister_node(child)
  end
end

--- Get all root nodes
function Tree:get_nodes()
  return self._nodes
end

--- Replace all root nodes
function Tree:set_nodes(nodes)
  self._nodes = nodes
  self._nodes_by_id = {}
  self._line_to_node = {}
  self:_register_nodes(self._nodes, 1)
end

--- Add a node (optionally as child of parent_id)
function Tree:add_node(node, parent_id)
  if parent_id then
    local parent = self._nodes_by_id[parent_id]
    if parent then
      parent._children[#parent._children + 1] = node
      node._parent_id = parent_id
      node._depth = parent._depth + 1
      self._nodes_by_id[node._id] = node
      if #node._children > 0 then
        self:_register_nodes(node._children, node._depth + 1)
      end
    end
  else
    self._nodes[#self._nodes + 1] = node
    node._depth = 1
    self._nodes_by_id[node._id] = node
    if #node._children > 0 then
      self:_register_nodes(node._children, 2)
    end
  end
end

--- Remove a node by ID
function Tree:remove_node(node_id)
  local node = self._nodes_by_id[node_id]
  if not node then
    return
  end

  if node._parent_id then
    local parent = self._nodes_by_id[node._parent_id]
    if parent then
      for i, child in ipairs(parent._children) do
        if child._id == node_id then
          table.remove(parent._children, i)
          break
        end
      end
    end
  else
    for i, n in ipairs(self._nodes) do
      if n._id == node_id then
        table.remove(self._nodes, i)
        break
      end
    end
  end

  self:_unregister_node(node)
end

--- Compatibility stub (nui-specific, not needed for our implementation)
function Tree:set_node(_id)
  -- no-op
end

--- Get node by various lookups:
--- - nil: node at cursor position in current window
--- - number: node at that line number
--- - string: node with that ID
function Tree:get_node(arg)
  if arg == nil then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
    if not ok then
      return nil
    end
    return self._line_to_node[cursor[1]]
  elseif type(arg) == "number" then
    return self._line_to_node[arg]
  else
    return self._nodes_by_id[tostring(arg)]
  end
end

--- Render tree to buffer
function Tree:render()
  if not self._bufnr or not vim.api.nvim_buf_is_valid(self._bufnr) then
    return
  end

  -- Collect visible nodes via depth-first traversal
  local visible_nodes = {}
  local function collect(nodes)
    for _, node in ipairs(nodes) do
      visible_nodes[#visible_nodes + 1] = node
      if node._expanded and #node._children > 0 then
        collect(node._children)
      end
    end
  end
  collect(self._nodes)

  -- Clear all _line values
  for _, node in pairs(self._nodes_by_id) do
    node._line = nil
  end
  self._line_to_node = {}

  -- Build lines and collect highlight info
  local lines = {}
  local line_highlights = {} -- [line_idx] = { {col_start, col_end, hl_group}, ... }
  local line_spacers = {} -- [line_idx] = spacer_size

  for i, node in ipairs(visible_nodes) do
    node._line = i
    self._line_to_node[i] = node

    if node.data and node.data.type == "group" and i > 1 then
      line_spacers[i] = 1
    end

    if self._prepare_node then
      local line_obj = self._prepare_node(node)
      if line_obj and line_obj._segments then
        lines[i] = line_obj:content()
        -- Collect highlight segments
        local hl_entries = {}
        local col = 0
        for _, seg in ipairs(line_obj._segments) do
          if seg.hl and seg.hl ~= "" and #seg.text > 0 then
            hl_entries[#hl_entries + 1] = { col, col + #seg.text, seg.hl }
          end
          col = col + #seg.text
        end
        if #hl_entries > 0 then
          line_highlights[i] = hl_entries
        end
      else
        lines[i] = node.text or ""
      end
    else
      lines[i] = node.text or ""
    end
  end

  -- Save and clear readonly/modifiable to avoid W10 warning
  local was_readonly = vim.bo[self._bufnr].readonly
  vim.bo[self._bufnr].readonly = false
  vim.bo[self._bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(self._bufnr, 0, -1, false, lines)

  -- Apply highlights
  vim.api.nvim_buf_clear_namespace(self._bufnr, self._ns_id, 0, -1)

  -- Apply virtual line spacers
  for line_idx, spacer_size in pairs(line_spacers) do
    local virt_lines = {}
    for _ = 1, spacer_size do
      table.insert(virt_lines, { { "", "" } })
    end
    pcall(vim.api.nvim_buf_set_extmark, self._bufnr, self._ns_id, line_idx - 1, 0, {
      virt_lines = virt_lines,
      virt_lines_above = true,
    })
  end

  for line_idx, entries in pairs(line_highlights) do
    for _, entry in ipairs(entries) do
      pcall(vim.api.nvim_buf_set_extmark, self._bufnr, self._ns_id, line_idx - 1, entry[1], {
        end_col = entry[2],
        hl_group = entry[3],
      })
    end
  end

  vim.bo[self._bufnr].modifiable = false
  vim.bo[self._bufnr].readonly = was_readonly
end

return Tree
