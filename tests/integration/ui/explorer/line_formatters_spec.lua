local config = require("codediff.config")
local line_layout = require("codediff.ui.explorer.line_layout")
local nodes = require("codediff.ui.explorer.nodes")
local tree = require("codediff.ui.explorer.tree")

local reset_config = function()
  config.options = vim.deepcopy(config.defaults)
end

local fixed_layout = function(text, hl)
  return {
    left = { { segments = { { text = text, hl = hl } } } },
    right = {},
  }
end

describe("Explorer line formatters", function()
  before_each(function()
    reset_config()
  end)

  after_each(function()
    reset_config()
  end)

  it("built-in callbacks are available for every explorer row type", function()
    -- The config uses nil sentinels so that the config module stays a leaf
    -- (no UI imports). Callers resolve nil to the built-ins in
    -- codediff.ui.explorer.formatters.
    assert.is_nil(config.options.explorer.formatters.file)
    assert.is_nil(config.options.explorer.formatters.folder)
    assert.is_nil(config.options.explorer.formatters.group)
    local defaults = require("codediff.ui.explorer.formatters")
    assert.is_function(defaults.file)
    assert.is_function(defaults.folder)
    assert.is_function(defaults.group)
    assert.equals("…", config.options.explorer.ellipsis)
  end)

  it("replaces complete file, folder, and group rows with formatter output", function()
    config.options.explorer.view_mode = "tree"
    config.options.explorer.flatten_dirs = false
    local contexts = {}
    config.options.explorer.formatters = {
      file = function(ctx)
        contexts.file = ctx
        return fixed_layout("custom file")
      end,
      folder = function(ctx)
        contexts.folder = ctx
        return fixed_layout("custom folder")
      end,
      group = function(ctx)
        contexts.group = ctx
        return fixed_layout("custom group")
      end,
    }

    local files = {
      { path = "src/one.lua", old_path = "src/old.lua", status = "M" },
      { path = "src/two.lua", status = "A" },
    }
    local root = tree.create_tree_data({ unstaged = files, staged = {}, conflicts = {} }, "/repo", nil, false, { unstaged = true, staged = false })[1]
    local folder = root._children[1]
    local file = folder._children[1]

    assert.equals("custom group", nodes.prepare_node(root, 40, nil, nil):content())
    assert.equals("custom folder", nodes.prepare_node(folder, 40, nil, nil):content())
    assert.equals("custom file", nodes.prepare_node(file, 40, nil, nil):content())

    assert.same({
      name = "unstaged",
      label = "Changes",
      file_count = 2,
      files = {
        { path = "src/one.lua", old_path = "src/old.lua", group = "unstaged", status = "M" },
        { path = "src/two.lua", group = "unstaged", status = "A" },
      },
      expanded = false,
    }, contexts.group)
    assert.equals("src", contexts.folder.name)
    assert.equals("src", contexts.folder.path)
    assert.equals("unstaged", contexts.folder.group)
    assert.equals(2, contexts.folder.file_count)
    assert.same(contexts.group.files, contexts.folder.files)
    assert.equals("src/one.lua", contexts.file.path)
    assert.equals("one.lua", contexts.file.filename)
    assert.equals("", contexts.file.directory)
    assert.equals("src/old.lua", contexts.file.old_path)
    assert.equals("unstaged", contexts.file.group)
    assert.equals("M", contexts.file.status)
    assert.equals("CodeDiffStatusModified", contexts.file.status_hl)
    assert.equals(1, contexts.file.status_right_margin)
    assert.equals("  ├ ", contexts.file.indent)
    assert.equals("NeoTreeIndentMarker", contexts.file.indent_hl)
  end)

  it("truncates display-width-aware regions by priority and preserves fixed status", function()
    local layout = {
      left = {
        { segments = { { text = "界界" } }, truncate_priority = 1 },
        { segments = { { text = "name" } }, truncate_priority = 2 },
      },
      right = {
        { segments = { { text = "M" } } },
      },
      min_gap = 2,
    }

    local content = line_layout.render(layout, 8):content()
    assert.equals("…name  M", content)
    assert.equals(8, vim.fn.strdisplaywidth(content))

    local custom = line_layout.render(layout, 10, nil, "..."):content()
    assert.equals("...name  M", custom)

    local narrow = line_layout.render(layout, 1):content()
    assert.equals("M", narrow)
  end)

  it("supports group names, colors, style tables, and selected backgrounds", function()
    local layout = {
      left = {
        {
          segments = {
            { text = "normal", hl = "Normal" },
            { text = " hex", hl = "#3fb950" },
            { text = " styled", hl = { fg = "#f00", bold = true } },
          },
        },
      },
      right = {},
    }

    local line = line_layout.render(layout, 40, 0x112233)
    local hex = vim.api.nvim_get_hl(0, { name = line._segments[2].hl, link = false })
    local styled = vim.api.nvim_get_hl(0, { name = line._segments[3].hl, link = false })
    assert.equals(0x3fb950, hex.fg)
    assert.equals(0x112233, hex.bg)
    assert.equals(0xff0000, styled.fg)
    assert.equals(0x112233, styled.bg)
    assert.is_true(styled.bold)
  end)

  it("keeps built-in status visible when a filename must be truncated", function()
    config.options.explorer.ellipsis = ".."
    local file = {
      path = "界界界-a-very-long-filename-that-needs-truncation.lua",
      status = "??",
    }
    local node = nodes.create_file_nodes({ file }, "/repo", "unstaged")[1]
    local content = nodes.prepare_node(node, 24, nil, nil):content()

    assert.matches("%.%.%s+%?%? %s*$", content)
    assert.equals(24, vim.fn.strdisplaywidth(content))
  end)
end)
