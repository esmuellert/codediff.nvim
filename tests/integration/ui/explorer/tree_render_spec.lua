-- Explorer tree content and file navigation.

local h = require("tests.support")
h.ensure_plugin_loaded()

describe("Explorer tree render", function()
  local repo

  before_each(function()
    require("codediff").setup({})
    repo = h.create_temp_git_repo()
    repo.write_file("src/a.txt", { "aaa" })
    repo.write_file("src/b.txt", { "bbb" })
    repo.write_file("c.txt", { "ccc" })
    repo.git("add .")
    repo.git("commit -m initial")
    repo.write_file("src/a.txt", { "aaa modified" })
    repo.write_file("src/b.txt", { "bbb modified" })
    repo.write_file("c.txt", { "ccc modified" })
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path("c.txt")))
  end)

  after_each(function()
    h.close_extra_tabs()
    if repo then
      repo.cleanup()
    end
  end)

  it("renders the changed files and reacts to next-file navigation", function()
    vim.cmd("CodeDiff")
    assert.is_true(h.wait_for_explorer(5000))
    assert.is_true(h.wait_for_diff_ready(5000))

    local lifecycle = require("codediff.ui.lifecycle")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local session = lifecycle.get_session(tabpage)
    assert.is_not_nil(session, "explorer session should exist")
    local explorer = (session.panel or {}).view
    assert.is_not_nil(explorer, "explorer object should be attached to the session")

    local _, explorer_buf = h.find_window_by_filetype("codediff-explorer")
    local content = h.get_buffer_content(explorer_buf)

    -- Every changed file must appear — no partial listing / silent filter.
    h.assert_contains(content, "a.txt", "explorer should list src/a.txt")
    h.assert_contains(content, "b.txt", "explorer should list src/b.txt")
    h.assert_contains(content, "c.txt", "explorer should list c.txt")
    h.assert_contains(content, "Changes", "explorer should show the 'Changes' group header")

    -- Next-file navigation must actually move the current selection to a
    -- different file. Calling `navigation.next_file()` directly (what `]f`
    -- binds to via lifecycle.set_tab_keymap) sidesteps the issue where
    -- nvim_feedkeys("]f", "nx") relies on which buffer is current at the
    -- time it drains — an artifact of feeding a tab-scoped keymap from an
    -- explorer buffer that shadows navigation entries with its own maps.
    local navigation = require("codediff.ui.view.navigation")
    local before = explorer.data.current_file_path
    assert.is_not_nil(before, "explorer should have a currently-selected file after opening")

    -- Only one changed file? Then next_file is a no-op by design (cycle over
    -- a single item), and asserting a change would be wrong. Guard.
    local all_files = require("codediff.ui.explorer.tree").get_all_files(explorer.tree)
    assert.is_true(#all_files >= 2,
      "test setup should produce >= 2 changed files, got " .. #all_files)

    navigation.next_file()
    -- next_file updates the session selection synchronously, but the
    -- diff render (view.update) runs via vim.schedule + async git.get_file.
    -- Wait for BOTH the explorer selection AND the modified buffer name to
    -- catch up, so the assertions below verify the full end-to-end path.
    vim.wait(5000, function()
      if explorer.data.current_file_path == before then return false end
      local _, buf = lifecycle.get_buffers(tabpage)
      if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
      return vim.api.nvim_buf_get_name(buf):find(explorer.data.current_file_path, 1, true) ~= nil
    end, 25)

    assert.are_not.equal(before, explorer.data.current_file_path,
      "next_file must select a different file; still on '" .. tostring(before) .. "'")

    -- And the modified pane must show that new file's content, not stale
    -- data from the previous selection.
    local _, mod_buf = lifecycle.get_buffers(tabpage)
    assert.is_not_nil(mod_buf)
    local mod_name = vim.api.nvim_buf_get_name(mod_buf)
    assert.is_true(
      mod_name:find(explorer.data.current_file_path, 1, true) ~= nil,
      "modified buffer name '" .. mod_name .. "' should match the newly-selected file '" .. explorer.data.current_file_path .. "'")
  end)
end)

