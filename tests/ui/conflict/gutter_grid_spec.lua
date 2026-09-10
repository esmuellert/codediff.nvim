local Screen = require("tests.framework.screen")
local gutter = require("tests.ui.conflict.gutter_helpers")
local cases = require("tests.fixtures.conflict_gutter")

describe("conflict block gutter on the screen grid", function()
  local screen

  after_each(function()
    if screen then
      screen:close()
      screen = nil
    end
  end)

  for index, case in ipairs(cases) do
    it(case.name .. " in all panes under each focus state", function()
      screen = Screen.new(120, 24)
      local panes = gutter.open_block(screen, index)
      local expected = gutter.block_rows(case)

      for _, focus in ipairs({ "original", "modified", "result" }) do
        screen:exec("vim.api.nvim_set_current_win(...)", { panes[focus] })
        screen:flush()
        for _, side in ipairs({ "original", "modified", "result" }) do
          gutter.expect_pane(screen, panes[side], expected[side], case.name .. ": " .. side .. " while focused on " .. focus, panes.foreground)
        end
      end
    end)
  end

  it("keeps BOF offsets correct when only part of the leading filler is visible", function()
    screen = Screen.new(120, 24)
    local panes = gutter.open_block(screen, 13)
    screen:exec(
      [[
      local win = ...
      vim.api.nvim_set_current_win(win)
      vim.fn.winrestview({ topline = 1, topfill = 1 })
    ]],
      { panes.original }
    )
    screen:flush()
    gutter.expect_pane(screen, panes.original, {
      "│ ╱╱╱╱",
      "│ one",
      "│ ╱╱╱╱",
      "╰─two",
      "  three",
      "  four",
      "  five",
      "  six",
    }, "partially scrolled BOF", panes.foreground)
  end)

  it("keeps after-line-one markers correct when all BOF filler is scrolled out", function()
    screen = Screen.new(120, 24)
    local panes = gutter.open_block(screen, 13)
    screen:exec(
      [[
      vim.api.nvim_set_current_win(...)
      vim.fn.winrestview({ topline = 1, topfill = 0 })
    ]],
      { panes.original }
    )
    screen:flush()
    gutter.expect_pane(screen, panes.original, {
      "│ one",
      "│ ╱╱╱╱",
      "╰─two",
      "  three",
      "  four",
      "  five",
      "  six",
    }, "hidden BOF", panes.foreground)
  end)

  for _, options in ipairs({
    { name = "number and fold columns", number = true, relativenumber = true, numberwidth = 6, foldcolumn = "2", signcolumn = "yes" },
    { name = "multiple sign slots", number = true, relativenumber = false, numberwidth = 4, foldcolumn = "0", signcolumn = "yes:2" },
    { name = "signs in the number column", number = true, relativenumber = true, numberwidth = 4, foldcolumn = "0", signcolumn = "number" },
    { name = "hidden signs", number = true, relativenumber = true, numberwidth = 4, foldcolumn = "0", signcolumn = "no" },
  }) do
    it("changes only filler sign cells with " .. options.name, function()
      screen = Screen.new(120, 24)
      local panes = gutter.open_block(screen, 3)
      local rect = screen:exec(
        [[
        local win, options = ...
        vim.api.nvim_set_current_win(win)
        require('codediff.ui.conflict').detach_gutter(win)
        for name, value in pairs(options) do
          if name ~= 'name' then vim.wo[win][name] = value end
        end
        local p = vim.api.nvim_win_get_position(win)
        return { p[1] + 1, p[2] + 1, vim.api.nvim_win_get_width(win), vim.fn.getwininfo(win)[1].textoff }
      ]],
        { panes.original, options }
      )
      screen:flush()
      local expected = {}
      for row = 1, 8 do
        expected[row] = screen:text(rect[1] + row - 1, rect[2], rect[3])
      end
      if options.signcolumn ~= "no" then
        local sign_col = options.signcolumn == "number" and rect[4] - 3 or tonumber(options.foldcolumn)
        for row, glyph in pairs({ [3] = "│ ", [4] = "╰─" }) do
          expected[row] = vim.fn.strcharpart(expected[row], 0, sign_col) .. glyph .. vim.fn.strcharpart(expected[row], sign_col + 2)
        end
      end
      screen:exec(
        [[
        local win, tab = ...
        local conflict = require('codediff.ui.conflict')
        conflict.attach_gutter(win)
        conflict.refresh(require('codediff.ui.lifecycle').get_session(tab))
      ]],
        { panes.original, panes.tab }
      )
      screen:flush()
      screen:expect_rows(rect[1], rect[2], expected, options.name)
    end)
  end

  it("composes separate blocks and removes one without damaging the other", function()
    screen = Screen.new(120, 24)
    local panes = gutter.open_block(screen, 3)
    screen:exec(
      [[
      local s = require('codediff.ui.lifecycle').get_session(...)
      s.conflict_blocks[2] = {
        base_range = { start_line = 7, end_line = 8 }, result_range = { start_line = 7, end_line = 8 },
        output1_range = { start_line = 5, end_line = 6 }, output2_range = { start_line = 7, end_line = 8 },
      }
      local conflict = require('codediff.ui.conflict')
      conflict.initialize_tracking(s.result_bufnr, s.conflict_blocks)
      conflict.refresh(s)
    ]],
      { panes.tab }
    )
    screen:flush()
    local expected = gutter.block_rows(cases[3])
    expected.original = { "  one", "╭─two", "│ ╱╱╱╱", "╰─╱╱╱╱", "  three", "  four", "[ five", "  six" }
    expected.modified[9] = "[ five"
    expected.result[7] = "[ base seven"
    for _, side in ipairs({ "original", "modified", "result" }) do
      gutter.expect_pane(screen, panes[side], expected[side], "two blocks: " .. side, panes.foreground)
    end
    screen:exec(
      [[
      local tab = ...
      local lifecycle = require('codediff.ui.lifecycle')
      local s = lifecycle.get_session(tab)
      lifecycle.set_conflict_blocks(tab, { s.conflict_blocks[2] })
      require('codediff.ui.conflict').refresh(s)
    ]],
      { panes.tab }
    )
    screen:flush()
    gutter.expect_pane(screen, panes.original, {
      "  one",
      "  two",
      "  ╱╱╱╱",
      "  ╱╱╱╱",
      "  three",
      "  four",
      "[ five",
      "  six",
    }, "only the second block remains", panes.foreground)
  end)

  it("renders no Result marker for an empty Result projection", function()
    screen = Screen.new(120, 24)
    local panes = gutter.open_block(screen, 3)
    screen:exec(
      [[
      local s = require('codediff.ui.lifecycle').get_session(...)
      s.conflict_blocks[1].result_range = { start_line = 4, end_line = 4 }
      local conflict = require('codediff.ui.conflict')
      conflict.initialize_tracking(s.result_bufnr, s.conflict_blocks)
      conflict.refresh(s)
    ]],
      { panes.tab }
    )
    screen:flush()
    gutter.expect_pane(screen, panes.result, {
      "  base one",
      "  base two",
      "  base three",
      "  base four",
      "  base five",
      "  base six",
      "  base seven",
    }, "empty Result projection")
    gutter.expect_pane(screen, panes.original, cases[3].rows, "nonempty input projection", panes.foreground)
  end)

  it("uses updated highlight colors on real and filler markers", function()
    screen = Screen.new(120, 24)
    local panes = gutter.open_block(screen, 3)
    screen:exec("vim.api.nvim_set_hl(0, 'CodeDiffConflictSign', { fg = 0x12ab34, bg = 0x345678, bold = true })")
    screen:flush()
    local expected = gutter.block_rows(cases[3])
    for _, side in ipairs({ "original", "modified", "result" }) do
      gutter.expect_pane(screen, panes[side], expected[side], "updated highlight: " .. side, { foreground = 0x12ab34, background = 0x345678, bold = true })
    end
  end)

  it("clears a removed block on both real and filler rows", function()
    screen = Screen.new(120, 24)
    local panes = gutter.open_block(screen, 3)
    screen:exec(
      [[
      local tab = ...
      local lifecycle = require('codediff.ui.lifecycle')
      lifecycle.set_conflict_blocks(tab, {})
      require('codediff.ui.conflict').refresh(lifecycle.get_session(tab))
    ]],
      { panes.tab }
    )
    screen:flush()
    gutter.expect_pane(screen, panes.original, {
      "  one",
      "  two",
      "  ╱╱╱╱",
      "  ╱╱╱╱",
      "  three",
      "  four",
      "  five",
      "  six",
    }, "removed block")
    gutter.expect_pane(screen, panes.result, {
      "  base one",
      "  base two",
      "  base three",
      "  base four",
      "  base five",
      "  base six",
      "  base seven",
    }, "removed Result block")
  end)
end)
