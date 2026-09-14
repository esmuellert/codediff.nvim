-- Explorer window position and layout.
-- Verifies that :CodeDiff opens the explorer at the LEFTMOST column (not
-- between the diff panes) and that the diff panes appear to its right.

local h = require("tests.support")
h.ensure_plugin_loaded()

describe("Explorer window layout", function()
  local repo
  local original_statuscolumn

  before_each(function()
    original_statuscolumn = vim.o.statuscolumn
    vim.o.statuscolumn = "%s%=%l %C "
    require("codediff").setup({})
    repo = h.create_temp_git_repo()
    repo.write_file("file1.txt", { "line 1", "line 2" })
    repo.write_file("file2.txt", { "hello" })
    repo.git("add .")
    repo.git("commit -m initial")
    repo.write_file("file1.txt", { "line 1", "line 2 modified" })
    repo.write_file("file2.txt", { "hello world" })
    vim.cmd("edit " .. repo.path("file1.txt"))
  end)

  after_each(function()
    vim.o.statuscolumn = original_statuscolumn
    h.close_extra_tabs()
    if repo then
      repo.cleanup()
    end
  end)

  it("puts the explorer at column 0 with diff panes to its right", function()
    vim.cmd("CodeDiff")
    assert.is_true(h.wait_for_explorer(5000), "explorer window should appear")
    assert.is_true(h.wait_for_diff_ready(5000), "diff session should register")

    local explorer_win = h.find_window_by_filetype("codediff-explorer")
    assert.is_not_nil(explorer_win, "explorer window not found")
    assert.equal("", vim.wo[explorer_win].statuscolumn,
      "explorer should not inherit the user's status column")
    assert.equal(0, vim.fn.getwininfo(explorer_win)[1].textoff,
      "explorer rows should use the full window width")

    local wins = vim.api.nvim_tabpage_list_wins(0)
    assert.is_true(#wins >= 3, "expected at least 3 windows (explorer + 2 diff panes), got " .. #wins)

    -- Explorer must be leftmost.
    local explorer_col = vim.api.nvim_win_get_position(explorer_win)[2]
    assert.equal(0, explorer_col,
      "explorer should be at column 0 (leftmost), got " .. explorer_col)

    -- Reasonable width — not filling the whole screen.
    local explorer_width = vim.api.nvim_win_get_width(explorer_win)
    assert.is_true(explorer_width <= 60,
      "explorer should be a reasonable width, got " .. explorer_width)

    -- Every other window is to the right of the explorer.
    for _, w in ipairs(wins) do
      if w ~= explorer_win then
        local col = vim.api.nvim_win_get_position(w)[2]
        assert.is_true(col > explorer_col,
          "diff pane at column " .. col .. " should be right of explorer at column " .. explorer_col)
      end
    end
  end)
end)
