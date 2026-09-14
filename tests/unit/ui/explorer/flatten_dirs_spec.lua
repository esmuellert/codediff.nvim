-- Test: Directory flattening in tree view
-- Validates that single-child directory chains are merged

local config = require("codediff.config")
local nodes = require("codediff.ui.explorer.nodes")

-- Helper: collect directory names from tree nodes recursively
local function collect_dir_names(tree_nodes)
  local dirs = {}
  for _, node in ipairs(tree_nodes) do
    if node.data and node.data.type == "directory" then
      dirs[#dirs + 1] = node.data.name
      -- Recurse into children
      if node:has_children() then
        for _, child_id in ipairs(node:get_child_ids()) do
          -- child_id is the node itself in our Tree implementation
          local child = child_id
          if type(child) == "table" and child.data then
            if child.data.type == "directory" then
              dirs[#dirs + 1] = child.data.name
            end
          end
        end
      end
    end
  end
  return dirs
end

-- Helper: recursively collect all node names (dirs and files)
local function collect_all_names(tree_nodes, result)
  result = result or {}
  for _, node in ipairs(tree_nodes) do
    if node.data then
      result[#result + 1] = {
        name = node.data.name or node.text,
        type = node.data.type,
      }
    end
  end
  return result
end

describe("Directory Flattening", function()
  local original_flatten

  before_each(function()
    config.setup({})
    original_flatten = config.options.explorer.flatten_dirs
  end)

  after_each(function()
    config.options.explorer.flatten_dirs = original_flatten
    config.options.explorer.view_mode = "list"
  end)

  it("Flattens single-child directory chains", function()
    config.options.explorer.view_mode = "tree"
    config.options.explorer.flatten_dirs = true

    local files = {
      { path = "src/utils/helpers/format.ts", status = "M" },
    }

    local tree_nodes = nodes.create_tree_file_nodes(files, "/tmp/repo", "unstaged")

    -- src/ -> utils/ -> helpers/ should flatten to a single dir node "src/utils/helpers"
    assert.equals(1, #tree_nodes)
    assert.equals("directory", tree_nodes[1].data.type)
    assert.equals("src/utils/helpers", tree_nodes[1].data.name)
  end)

  it("Does not flatten directories with multiple children", function()
    config.options.explorer.view_mode = "tree"
    config.options.explorer.flatten_dirs = true

    local files = {
      { path = "src/foo.ts", status = "M" },
      { path = "src/bar.ts", status = "M" },
    }

    local tree_nodes = nodes.create_tree_file_nodes(files, "/tmp/repo", "unstaged")

    -- src/ has two file children, should NOT be flattened
    assert.equals(1, #tree_nodes)
    assert.equals("directory", tree_nodes[1].data.type)
    assert.equals("src", tree_nodes[1].data.name)
  end)

  it("Flattens partial chains correctly", function()
    config.options.explorer.view_mode = "tree"
    config.options.explorer.flatten_dirs = true

    local files = {
      { path = "a/b/c/file1.ts", status = "M" },
      { path = "a/b/c/file2.ts", status = "A" },
    }

    local tree_nodes = nodes.create_tree_file_nodes(files, "/tmp/repo", "unstaged")

    -- a/ -> b/ -> c/ : c has 2 files so stops there
    -- a/ -> b/ each have single dir child -> flatten to "a/b/c"
    assert.equals(1, #tree_nodes)
    assert.equals("a/b/c", tree_nodes[1].data.name)
  end)

  it("Does not flatten when disabled", function()
    config.options.explorer.view_mode = "tree"
    config.options.explorer.flatten_dirs = false

    local files = {
      { path = "src/utils/helpers/format.ts", status = "M" },
    }

    local tree_nodes = nodes.create_tree_file_nodes(files, "/tmp/repo", "unstaged")

    -- Should NOT flatten - "src" with nested dirs
    assert.equals(1, #tree_nodes)
    assert.equals("src", tree_nodes[1].data.name)
  end)

  it("Handles mixed files and directories without flattening", function()
    config.options.explorer.view_mode = "tree"
    config.options.explorer.flatten_dirs = true

    local files = {
      { path = "src/index.ts", status = "M" },
      { path = "src/lib/auth/oauth.ts", status = "M" },
    }

    local tree_nodes = nodes.create_tree_file_nodes(files, "/tmp/repo", "unstaged")

    -- src/ has a file (index.ts) and a dir (lib/) -> not flattened
    assert.equals(1, #tree_nodes)
    assert.equals("src", tree_nodes[1].data.name)
  end)
end)
