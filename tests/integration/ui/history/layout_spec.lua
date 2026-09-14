-- History panel layout and content.

local h = require("tests.support")
h.ensure_plugin_loaded()

describe("History layout", function()
  local repo
  local original_statuscolumn

  before_each(function()
    original_statuscolumn = vim.o.statuscolumn
    vim.o.statuscolumn = "%s%=%l %C "
    require("codediff").setup({})
    repo = h.create_temp_git_repo()
    repo.write_file("file.txt", { "version 1" })
    repo.git("add .")
    repo.git("commit -m first")
    repo.write_file("file.txt", { "version 2" })
    repo.git("add .")
    repo.git("commit -m second")
    repo.write_file("file.txt", { "version 3" })
    repo.git("add .")
    repo.git("commit -m third")
    vim.cmd("edit " .. repo.path("file.txt"))
  end)

  after_each(function()
    vim.o.statuscolumn = original_statuscolumn
    h.close_extra_tabs()
    if repo then
      repo.cleanup()
    end
  end)

  it("opens a history panel at the bottom with commit content", function()
    vim.cmd("CodeDiff history")

    -- Wait for the history panel to appear.
    local appeared = vim.wait(5000, function()
      return h.find_window_by_filetype("codediff-history") ~= nil
    end, 50)
    assert.is_true(appeared, "history panel should appear within 5s")

    local history_win, history_buf = h.find_window_by_filetype("codediff-history")
    assert.is_not_nil(history_win)
    assert.is_not_nil(history_buf)
    assert.equal("", vim.wo[history_win].statuscolumn,
      "history should not inherit the user's status column")
    assert.equal(0, vim.fn.getwininfo(history_win)[1].textoff,
      "history rows should use the full window width")

    local content = h.get_buffer_content(history_buf)
    local lines = h.get_buffer_lines(history_buf)
    assert.is_true(#lines > 0, "history buffer should have lines")
    h.assert_contains(content, "Commit History",
      "history panel should show 'Commit History' title")

    -- History is at the bottom: its row position is >= every other window's.
    local history_row = vim.api.nvim_win_get_position(history_win)[1]
    for _, other_win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if other_win ~= history_win then
        local other_row = vim.api.nvim_win_get_position(other_win)[1]
        assert.is_true(history_row >= other_row,
          "history should be at bottom (row " .. history_row .. " vs other " .. other_row .. ")")
      end
    end
  end)
end)
