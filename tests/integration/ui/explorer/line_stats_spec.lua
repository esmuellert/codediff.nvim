local config = require("codediff.config")
local line_stats = require("codediff.ui.explorer.line_stats")
local nodes = require("codediff.ui.explorer.nodes")
local tree = require("codediff.ui.explorer.tree")

local reset_config = function()
  config.options = vim.deepcopy(config.defaults)
end

local fixed_layout = function(text)
  return {
    left = { { segments = { { text = text } } } },
    right = {},
  }
end

describe("Explorer line stats", function()
  before_each(reset_config)
  after_each(reset_config)

  it("is disabled by default without importing formatter defaults into config", function()
    local options = config.options.explorer
    assert.same({ enabled = false, count_untracked = false, max_untracked_bytes = 1024 * 1024 }, options.line_stats)
    assert.is_nil(options.formatters.file)
    assert.is_nil(options.formatters.folder)
    assert.is_nil(options.formatters.group)
  end)

  it("aggregates text, binary, and unavailable files", function()
    assert.same(
      {
        files_changed = 3,
        insertions = 3,
        deletions = 2,
        binary_files = 1,
        unavailable_files = 1,
      },
      line_stats.sum({
        { line_stats = { insertions = 3, deletions = 2, binary = false } },
        { line_stats = { insertions = 0, deletions = 0, binary = true } },
        {},
      })
    )
  end)

  it("renders right-aligned file stats and aggregate group totals", function()
    config.options.explorer.line_stats.enabled = true
    local files = {
      { path = "added.lua", status = "A", line_stats = { insertions = 20, deletions = 0, binary = false } },
      { path = "changed.lua", status = "M", line_stats = { insertions = 22, deletions = 8, binary = false } },
      { path = "image.png", status = "M", line_stats = { insertions = 0, deletions = 0, binary = true } },
    }
    local root = tree.create_tree_data({ unstaged = files, staged = {}, conflicts = {} }, "/repo", nil, false, {
      unstaged = true,
      staged = false,
    })[1]

    local group_line = nodes.prepare_node(root, 50, nil, nil)
    assert.equals(" Changes (3 · +42 -8)", group_line:content())
    local file_nodes = nodes.create_file_nodes(files, "/repo", "unstaged")
    local changed_line = nodes.prepare_node(file_nodes[2], 50, nil, nil)
    local changed = changed_line:content()
    assert.matches("changed%.lua%s+%+22 %-8 M%s*$", changed)
    assert.equals(50, vim.fn.strdisplaywidth(changed))
    local binary_line = nodes.prepare_node(file_nodes[3], 50, nil, nil)
    assert.matches("image%.png%s+bin M%s*$", binary_line:content())

    local highlights = {}
    for _, line in ipairs({ group_line, changed_line, binary_line }) do
      for _, segment in ipairs(line._segments) do
        highlights[segment.hl] = true
      end
    end
    assert.is_true(highlights.CodeDiffExplorerStatFiles)
    assert.is_true(highlights.CodeDiffExplorerStatInsertions)
    assert.is_true(highlights.CodeDiffExplorerStatDeletions)
    assert.is_true(highlights.CodeDiffExplorerStatBinary)
  end)

  it("exposes stats in existing file, folder, and group formatter metadata", function()
    config.options.explorer.view_mode = "tree"
    config.options.explorer.flatten_dirs = false
    config.options.explorer.line_stats.enabled = true
    local contexts = {}
    config.options.explorer.formatters = {
      file = function(ctx)
        contexts.file = ctx
        return fixed_layout("file")
      end,
      folder = function(ctx)
        contexts.folder = ctx
        return fixed_layout("folder")
      end,
      group = function(ctx)
        contexts.group = ctx
        return fixed_layout("group")
      end,
    }

    local files = {
      { path = "src/one.lua", status = "M", line_stats = { insertions = 3, deletions = 2, binary = false } },
      { path = "src/two.lua", status = "A", line_stats = { insertions = 4, deletions = 0, binary = false } },
    }
    local root = tree.create_tree_data({ unstaged = files, staged = {}, conflicts = {} }, "/repo", nil, false, {
      unstaged = true,
      staged = false,
    })[1]
    local folder = root._children[1]
    local file = folder._children[1]

    nodes.prepare_node(root, 40, nil, nil)
    nodes.prepare_node(folder, 40, nil, nil)
    nodes.prepare_node(file, 40, nil, nil)
    local aggregate = { files_changed = 2, insertions = 7, deletions = 2, binary_files = 0, unavailable_files = 0 }
    assert.same(aggregate, contexts.group.stats)
    assert.same(aggregate, contexts.folder.stats)
    assert.same({ insertions = 3, deletions = 2, binary = false }, contexts.file.stats)
    assert.same({
      path = "src/one.lua",
      group = "unstaged",
      status = "M",
      stats = { insertions = 3, deletions = 2, binary = false },
    }, contexts.group.files[1])
    assert.same(contexts.group.files, contexts.folder.files)

    config.options.explorer.line_stats.enabled = false
    nodes.prepare_node(root, 40, nil, nil)
    nodes.prepare_node(folder, 40, nil, nil)
    nodes.prepare_node(file, 40, nil, nil)
    assert.is_nil(contexts.group.stats)
    assert.is_nil(contexts.folder.stats)
    assert.is_nil(contexts.file.stats)
    assert.is_nil(contexts.group.files[1].stats)
  end)

  it("truncates stats before the fixed status", function()
    config.options.explorer.line_stats.enabled = true
    local file = {
      path = "a-very-long-filename-that-needs-truncation.lua",
      status = "??",
      line_stats = { insertions = 123, deletions = 45, binary = false },
    }
    local node = nodes.create_file_nodes({ file }, "/repo", "unstaged")[1]
    local wide = nodes.prepare_node(node, 40, nil, nil):content()
    assert.matches("…%s+%+123 %-45 %?%? %s*$", wide)
    assert.equals(40, vim.fn.strdisplaywidth(wide))

    local narrow = nodes.prepare_node(node, 3, nil, nil):content()
    assert.equals("?? ", narrow)
    assert.is_nil(narrow:find("+", 1, true))
  end)
end)
