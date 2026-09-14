-- Explorer hide/show (toggle visibility).

local h = require("tests.support")
h.ensure_plugin_loaded()

describe("Explorer toggle visibility", function()
  local repo

  before_each(function()
    require("codediff").setup({})
    repo = h.create_temp_git_repo()
    repo.write_file("file.txt", { "original" })
    repo.git("add .")
    repo.git("commit -m initial")
    repo.write_file("file.txt", { "modified" })
    vim.cmd("edit " .. repo.path("file.txt"))
  end)

  after_each(function()
    h.close_extra_tabs()
    if repo then
      repo.cleanup()
    end
  end)

  it("hides then restores the explorer at the left edge", function()
    vim.cmd("CodeDiff")
    assert.is_true(h.wait_for_explorer(5000))
    assert.is_true(h.wait_for_diff_ready(5000))

    local actions = require("codediff.ui.explorer.actions")
    local lifecycle = require("codediff.ui.lifecycle")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local explorer_obj = (lifecycle.get_session(tabpage).panel or {}).view
    assert.is_not_nil(explorer_obj, "explorer object should be attached to the session")

    -- Snapshot: initial state.
    local initial_explorer_win = h.find_window_by_filetype("codediff-explorer")
    local initial_win_count = #vim.api.nvim_tabpage_list_wins(tabpage)
    assert.is_not_nil(initial_explorer_win, "explorer should exist initially")

    -- Hide → the explorer window disappears and the tab has fewer windows.
    actions.toggle_visibility(explorer_obj)
    vim.wait(500)
    assert.is_nil(h.find_window_by_filetype("codediff-explorer"),
      "explorer window should be gone after hiding")
    assert.is_true(#vim.api.nvim_tabpage_list_wins(tabpage) < initial_win_count,
      "window count should decrease after hide")

    -- Restore → the explorer reappears with the same window count and column 0.
    actions.toggle_visibility(explorer_obj)
    vim.wait(500)
    local restored_win = h.find_window_by_filetype("codediff-explorer")
    assert.is_not_nil(restored_win, "explorer should be restored after second toggle")
    assert.equal(initial_win_count, #vim.api.nvim_tabpage_list_wins(tabpage),
      "window count should match the original after restore")
    assert.equal(0, vim.api.nvim_win_get_position(restored_win)[2],
      "restored explorer should still be at column 0 (leftmost)")
  end)
end)
