-- Regression test for https://github.com/esmuellert/codediff.nvim/pull/309
-- Tab cycling with an untracked file selected must not crash.
--
-- Root cause: show_untracked_file() used to store `{}` as stored_diff_result
-- instead of `{changes={}, moves={}}`. When resume_diff() later reused that
-- value (no recompute needed on tab reentry), render_diff() crashed on
-- ipairs(nil) because {}.changes is nil.
--
-- The spec first asserts the invariant directly (stored_diff_result.changes
-- must be a table right after selecting the untracked file), then exercises
-- the full suspend → resume path via a tabnew + tabnext to catch a re-break.

local h = require("tests.support")
h.ensure_plugin_loaded()

describe("PR #309 regression — tab cycle with an untracked file", function()
  local repo
  local lifecycle = require("codediff.ui.lifecycle")

  before_each(function()
    require("codediff").setup({})
    repo = h.create_temp_git_repo()
    repo.write_file("tracked.txt", { "hello world" })
    repo.git("add .")
    repo.git("commit -m initial")
    repo.write_file("untracked.txt", { "I am untracked" })
    vim.cmd("edit " .. repo.path("tracked.txt"))
  end)

  after_each(function()
    h.close_extra_tabs()
    if repo then
      repo.cleanup()
    end
  end)

  -- Locate the tree line for `untracked.txt` inside the explorer buffer,
  -- expanding a collapsed section if necessary. Returns the line number or nil.
  local function find_untracked_line(explorer_buf)
    local function search()
      local lines = h.get_buffer_lines(explorer_buf)
      for i, line in ipairs(lines) do
        if line:find("untracked.txt", 1, true) then
          return i, lines
        end
      end
      return nil, lines
    end

    local line, lines = search()
    if line then
      return line
    end
    -- Section may be collapsed; expand any node whose text contains "ntracked".
    for i, l in ipairs(lines) do
      if l:find("ntracked") then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
        vim.wait(500)
        break
      end
    end
    return (search())
  end

  it("selecting an untracked file initializes stored_diff_result.changes/moves", function()
    vim.cmd("CodeDiff")
    assert.is_true(h.wait_for_explorer(5000))
    assert.is_true(h.wait_for_diff_ready(5000))

    -- Focus the explorer to run its keymaps.
    local explorer_win, explorer_buf = h.find_window_by_filetype("codediff-explorer")
    assert.is_not_nil(explorer_win)
    vim.api.nvim_set_current_win(explorer_win)

    local target_line = find_untracked_line(explorer_buf)
    assert.is_not_nil(target_line, "untracked.txt should be findable in the explorer tree; buffer:\n" .. h.get_buffer_content(explorer_buf))

    -- Select it → triggers show_untracked_file → single-pane view.
    vim.api.nvim_win_set_cursor(explorer_win, { target_line, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
    vim.wait(1000)

    -- Core invariant: stored_diff_result must have .changes and .moves as
    -- tables right after show_untracked_file. Before the PR #309 fix these
    -- were nil and the subsequent resume_diff crashed.
    local tabpage = vim.api.nvim_get_current_tabpage()
    local session = lifecycle.get_session(tabpage)
    assert.is_not_nil(session, "session should exist after selecting a file")
    assert.is_not_nil(session.stored_diff_result, "stored_diff_result should be set after show_untracked_file")
    assert.equal("table", type(session.stored_diff_result.changes), "stored_diff_result.changes must be a table (was: " .. type(session.stored_diff_result.changes) .. ")")
    assert.equal("table", type(session.stored_diff_result.moves), "stored_diff_result.moves must be a table (was: " .. type(session.stored_diff_result.moves) .. ")")
  end)

  it("tabnew then tabnext to a codediff tab with an untracked file selected does not crash", function()
    -- Same setup as above — get to a state where untracked.txt is being viewed.
    vim.cmd("CodeDiff")
    assert.is_true(h.wait_for_explorer(5000))
    assert.is_true(h.wait_for_diff_ready(5000))

    local explorer_win, explorer_buf = h.find_window_by_filetype("codediff-explorer")
    vim.api.nvim_set_current_win(explorer_win)
    local target_line = find_untracked_line(explorer_buf)
    assert.is_not_nil(target_line)

    vim.api.nvim_win_set_cursor(explorer_win, { target_line, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
    vim.wait(1000)

    -- Now trigger the suspend → resume cycle: open a fresh tab, then jump
    -- back. TabEnter runs resume_diff via vim.schedule, which used to crash
    -- because stored_diff_result was `{}`.
    local codediff_tabpage = vim.api.nvim_get_current_tabpage()
    local codediff_tabnr = vim.fn.tabpagenr()
    vim.cmd("tabnew")
    vim.wait(500)

    local cycled_ok, cycle_err = pcall(function()
      vim.cmd("tabnext " .. codediff_tabnr)
    end)
    assert.is_true(cycled_ok, "tabnext back to the codediff tab must not error: " .. tostring(cycle_err))

    -- Let the scheduled resume_diff land.
    vim.wait(3000, function()
      local s = lifecycle.get_session(codediff_tabpage)
      return s and not s.suspended
    end, 50)

    local after = lifecycle.get_session(codediff_tabpage)
    assert.is_not_nil(after, "session should survive the tab cycle")
    assert.is_false(after.suspended, "session should be resumed after tab cycle")
    assert.is_true(after.modified_win and vim.api.nvim_win_is_valid(after.modified_win), "modified window should be valid after tab cycle")
  end)
end)
