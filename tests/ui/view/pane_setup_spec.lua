-- Window setup done by side_by_side.create: which pane lands on which side,
-- and the window options both panes get. Both were uncovered -- stubbing
-- either left the whole suite green.

local h = dofile("tests/helpers.lua")
local path = require("codediff.core.path")
local config = require("codediff.config")

describe("diff pane setup", function()
  local left, right, saved_position

  before_each(function()
    h.ensure_plugin_loaded()
    saved_position = config.options.diff.original_position
    left = h.get_temp_path("pane_setup_left.txt")
    right = h.get_temp_path("pane_setup_right.txt")
    vim.fn.writefile({ "a", "b", "c" }, left)
    vim.fn.writefile({ "a", "B", "c" }, right)
  end)

  after_each(function()
    config.options.diff.original_position = saved_position
    vim.fn.delete(left)
    vim.fn.delete(right)
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
  end)

  --- Open a two-file diff and return its session once rendered.
  local function open_diff()
    require("codediff.ui.view").create({
      original = path.make_ref(left, nil),
      modified = path.make_ref(right, nil),
    })
    local lifecycle = require("codediff.ui.lifecycle")
    local tabpage = vim.api.nvim_get_current_tabpage()
    assert.is_true(
      vim.wait(10000, function()
        local s = lifecycle.get_session(tabpage)
        return s ~= nil and s.stored_diff_result ~= nil
      end, 50),
      "diff never became ready"
    )
    return lifecycle.get_session(tabpage)
  end

  --- Screen column of a window's left edge, for ordering panes left to right.
  local function col_of(win)
    return vim.api.nvim_win_get_position(win)[2]
  end

  it("puts the original pane on the left by default", function()
    config.options.diff.original_position = "left"
    local session = open_diff()

    assert.is_true(
      col_of(session.original_win) < col_of(session.modified_win),
      "original pane should sit left of the modified pane"
    )
  end)

  it("honours original_position = 'right'", function()
    -- The split direction flips so the *new* window lands on the left; without
    -- it the setting silently does nothing.
    config.options.diff.original_position = "right"
    local session = open_diff()

    assert.is_true(
      col_of(session.original_win) > col_of(session.modified_win),
      "original pane should sit right of the modified pane"
    )
  end)

  it("applies the diff window options to both panes", function()
    local session = open_diff()

    for _, win in ipairs({ session.original_win, session.modified_win }) do
      -- nowrap is load-bearing for native scrollbind alignment.
      assert.is_false(vim.wo[win].wrap, "diff panes must not wrap")
      assert.is_true(vim.wo[win].cursorline, "diff panes should show cursorline")
      assert.is_false(vim.wo[win].list, "diff panes should not show listchars")
    end
  end)
end)
