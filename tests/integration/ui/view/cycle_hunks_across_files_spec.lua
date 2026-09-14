-- Regression test for https://github.com/esmuellert/codediff.nvim/issues/161
-- cycle_hunks_across_files: ]c on the last hunk of file A jumps to the first
-- hunk of file B (next in the explorer list); [c on the first hunk of file B
-- jumps to the LAST hunk of file A (the natural backward walk).

local h = require("tests.support")

describe("cycle_hunks_across_files (#161)", function()
  local repo
  local nav, lifecycle, config

  before_each(function()
    h.ensure_plugin_loaded()
    -- M.setup merges over M.options (not defaults), so reset to defaults
    -- first to undo any config from earlier tests.
    local cfg = require("codediff.config")
    cfg.options = vim.deepcopy(cfg.defaults)

    repo = h.create_temp_git_repo()
    -- Two files, each with TWO hunks.
    repo.write_file("a.txt", { "a1", "a2", "a3", "a4", "a5", "a6", "a7" })
    repo.write_file("b.txt", { "b1", "b2", "b3", "b4", "b5", "b6", "b7" })
    repo.write_file("d-deleted.txt", { "deleted" })
    repo.git("add .")
    repo.git("commit -m initial")
    repo.write_file("a.txt", { "a1 EDIT", "a2", "a3", "a4", "a5 EDIT", "a6", "a7" })
    repo.write_file("b.txt", { "b1 EDIT", "b2", "b3", "b4", "b5 EDIT", "b6", "b7" })
    repo.write_file("c-untracked.txt", { "untracked" })
    vim.fn.delete(repo.path("d-deleted.txt"))

    nav = require("codediff.ui.view.navigation")
    lifecycle = require("codediff.ui.lifecycle")
    config = require("codediff.config")
  end)

  after_each(function()
    if repo then
      repo.cleanup()
    end
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose")
    end
  end)

  local function has_expected_hunk_count(session, expected_count)
    local changes = session and session.stored_diff_result and session.stored_diff_result.changes
    if not changes then
      return false
    end
    if expected_count ~= nil then
      return #changes == expected_count
    end
    return #changes > 0
  end

  -- Open `:CodeDiff` against the temp repo and wait until the diff for
  -- the focused file is fully loaded with the expected hunk count.
  local function open_explorer(focus_file, expected_hunk_count)
    vim.cmd("edit " .. repo.dir .. "/" .. focus_file)
    require("codediff.commands").vscode_diff({ fargs = {} })

    local ok = vim.wait(8000, function()
      for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
        local s = lifecycle.get_session(tp)
        local e = lifecycle.get_panel_view(tp)
        if has_expected_hunk_count(s, expected_hunk_count) and e and e.data.current_file_path == focus_file then
          return true
        end
      end
      return false
    end, 50)
    if not ok then
      return nil
    end
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local s = lifecycle.get_session(tp)
      local e = lifecycle.get_panel_view(tp)
      if s and e then
        return tp, s, e
      end
    end
  end

  -- Wait for the displayed file to switch AND its diff to fully re-render.
  local function wait_for_file_switch(tabpage, from_file, expected_hunk_count)
    local switched = vim.wait(8000, function()
      local e = lifecycle.get_panel_view(tabpage)
      return e and e.data.current_file_path and e.data.current_file_path ~= from_file
    end, 20)
    if not switched then
      return false
    end
    return vim.wait(8000, function()
      local s = lifecycle.get_session(tabpage)
      local e = lifecycle.get_panel_view(tabpage)
      local session_path = s and s.modified.absolute ~= "" and s.modified.absolute or s and s.original.absolute
      return session_path and e and e.data.current_file_path and session_path:find(e.data.current_file_path, 1, true) ~= nil and has_expected_hunk_count(s, expected_hunk_count)
    end, 20)
  end

  it("OFF: ]c on the last hunk wraps within the same file (legacy behavior)", function()
    -- Explicitly disable the option to verify the legacy code path still
    -- works when the user opts out of cross-file cycling.
    local cfg = require("codediff.config")
    cfg.options = vim.deepcopy(cfg.defaults)
    cfg.options.diff.cycle_hunks_across_files = false

    local tabpage, session, explorer = open_explorer("a.txt")
    assert.is_not_nil(session)
    assert.is_not_nil(explorer)
    assert.is_false(config.options.diff.cycle_hunks_across_files, "option must be false for this test")

    local starting_file = explorer.data.current_file_path
    local changes = session.stored_diff_result.changes
    assert.is_true(#changes >= 2, "test repo must produce at least 2 hunks")

    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { changes[#changes].modified.start_line, 0 })

    nav.next_hunk()
    vim.wait(150)

    assert.equal(starting_file, explorer.data.current_file_path, "with cross-file off, ]c at the last hunk must NOT change file")
  end)

  it("OFF: hunk navigation does not leave a file with no hunks", function()
    config.options.diff.cycle_hunks_across_files = false

    local _, session, explorer = open_explorer("c-untracked.txt", 0)
    assert.is_not_nil(session)
    assert.is_not_nil(explorer)
    assert.equal(0, #session.stored_diff_result.changes)
    local starting_file = explorer.data.current_file_path

    assert.is_false(nav.next_hunk())
    assert.equal(starting_file, explorer.data.current_file_path)
    assert.is_false(nav.prev_hunk())
    assert.equal(starting_file, explorer.data.current_file_path)
    assert.is_nil(session.pending_cursor_landing)
  end)

  it("ON: ]c cycles forward from an untracked file with no hunks", function()
    config.options.diff.cycle_hunks_across_files = true

    local tabpage, session, explorer = open_explorer("c-untracked.txt", 0)
    assert.is_not_nil(session)
    assert.is_not_nil(explorer)
    assert.equal(0, #session.stored_diff_result.changes)

    assert.is_true(nav.next_hunk())
    assert.is_true(wait_for_file_switch(tabpage, "c-untracked.txt"))
    assert.equal("a.txt", explorer.data.current_file_path)
    assert.is_nil(lifecycle.get_session(tabpage).pending_cursor_landing)
  end)

  it("ON: [c cycles through untracked and deleted files with no hunks", function()
    config.options.diff.cycle_hunks_across_files = true

    local tabpage, session, explorer = open_explorer("c-untracked.txt", 0)
    assert.is_not_nil(session)
    assert.is_not_nil(explorer)

    assert.is_true(nav.prev_hunk())
    assert.is_true(wait_for_file_switch(tabpage, "c-untracked.txt", 0))
    assert.equal("d-deleted.txt", explorer.data.current_file_path)

    assert.is_true(nav.prev_hunk())
    assert.is_true(wait_for_file_switch(tabpage, "d-deleted.txt"))
    assert.equal("b.txt", explorer.data.current_file_path)
    assert.is_nil(lifecycle.get_session(tabpage).pending_cursor_landing)
  end)

  it("ON: ]c on the last hunk hops to the FIRST hunk of the next file", function()
    config.options.diff.cycle_hunks_across_files = true

    local tabpage, session, explorer = open_explorer("a.txt")
    assert.is_not_nil(session)
    assert.is_not_nil(explorer)
    local first_file = explorer.data.current_file_path

    local changes = session.stored_diff_result.changes
    assert.is_true(#changes >= 2)

    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { changes[#changes].modified.start_line, 0 })

    nav.next_hunk()

    assert.is_true(wait_for_file_switch(tabpage, first_file), "after ]c at boundary, explorer must switch to a different file")

    local new_session = lifecycle.get_session(tabpage)
    local first_hunk_line = new_session.stored_diff_result.changes[1].modified.start_line
    local cursor_after = vim.api.nvim_win_get_cursor(new_session.modified_win)[1]
    assert.equal(first_hunk_line, cursor_after, "after ]c hop, cursor must land on the FIRST hunk of the new file")
  end)

  it("ON: [c on the first hunk hops to the LAST hunk of the previous file", function()
    config.options.diff.cycle_hunks_across_files = true

    local tabpage, session, explorer = open_explorer("b.txt")
    assert.is_not_nil(session)
    assert.is_not_nil(explorer)
    local first_file = explorer.data.current_file_path

    local changes = session.stored_diff_result.changes
    assert.is_true(#changes >= 2)

    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { changes[1].modified.start_line, 0 })

    nav.prev_hunk()

    assert.is_true(wait_for_file_switch(tabpage, first_file), "after [c at boundary, explorer must switch to a different file")

    local new_session = lifecycle.get_session(tabpage)
    local last_hunk_line = new_session.stored_diff_result.changes[#new_session.stored_diff_result.changes].modified.start_line
    local cursor_after = vim.api.nvim_win_get_cursor(new_session.modified_win)[1]
    assert.equal(last_hunk_line, cursor_after, "after [c hop, cursor must land on the LAST hunk of the previous file (natural backward walk)")
  end)

  it("ON: pending_cursor_landing is consumed (one-shot, cleared after use)", function()
    config.options.diff.cycle_hunks_across_files = true

    local tabpage, session, explorer = open_explorer("a.txt")
    assert.is_not_nil(session)
    local first_file = explorer.data.current_file_path
    local changes = session.stored_diff_result.changes

    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { changes[#changes].modified.start_line, 0 })
    nav.next_hunk()
    assert.is_true(wait_for_file_switch(tabpage, first_file))

    -- The pending landing flag must have been cleared by the render path.
    local s = lifecycle.get_session(tabpage)
    assert.is_nil(s.pending_cursor_landing, "pending_cursor_landing must be cleared after use; otherwise it would leak to the next render")
  end)

  it("ON in INLINE mode: [c on first hunk hops to LAST hunk of previous file", function()
    -- Inline mode uses a different render path (`inline_view/render.lua`) than
    -- the side-by-side path (`view/render.lua`). Both honor pending_cursor_landing.
    local cfg = require("codediff.config")
    cfg.options = vim.deepcopy(cfg.defaults)
    cfg.options.diff.layout = "inline"
    cfg.options.diff.cycle_hunks_across_files = true

    local tabpage, session, explorer = open_explorer("b.txt")
    assert.is_not_nil(session)
    local first_file = explorer.data.current_file_path
    local changes = session.stored_diff_result.changes
    assert.is_true(#changes >= 2)

    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { changes[1].modified.start_line, 0 })

    nav.prev_hunk()
    assert.is_true(wait_for_file_switch(tabpage, first_file), "inline mode: explorer must switch to a different file after [c at boundary")

    local new_session = lifecycle.get_session(tabpage)
    local last_hunk_line = new_session.stored_diff_result.changes[#new_session.stored_diff_result.changes].modified.start_line
    local cursor_after = vim.api.nvim_win_get_cursor(new_session.modified_win)[1]
    assert.equal(last_hunk_line, cursor_after, "inline mode: cursor must land on the LAST hunk of the previous file (not the first)")
  end)

  it("ON: [c lands on the MODIFIED-side last hunk when original/modified line numbers diverge", function()
    -- Real-world files often have insertions so original-side and
    -- modified-side line numbers differ. Use a file with a 5-line
    -- INSERTION so the last hunk's modified.start_line is far away
    -- from its original.start_line. The bug (now fixed) was that the
    -- backward landing picked .original.start_line, which would put
    -- the cursor on the wrong physical line in the modified pane.
    local cfg = require("codediff.config")
    cfg.options = vim.deepcopy(cfg.defaults)
    cfg.options.diff.cycle_hunks_across_files = true

    -- a.txt is heavily extended: the second hunk lives at modified line ~13
    -- but original line ~7 (a 5-line insertion shifts things).
    repo.write_file("a.txt", { "k1", "k2", "k3", "k4", "k5", "k6", "k7" })
    repo.write_file("b.txt", { "b1", "b2", "b3", "b4", "b5" })
    repo.git("add .")
    repo.git("commit -m base2")
    repo.write_file("a.txt", {
      "k1 EDIT",
      "k2",
      "INS-1", -- inserted
      "INS-2", -- inserted
      "INS-3", -- inserted
      "INS-4", -- inserted
      "INS-5", -- inserted
      "k3",
      "k4",
      "k5",
      "k6 EDIT", -- second hunk: modified line ~11, original line ~6
      "k7",
    })
    repo.write_file("b.txt", { "b1 EDIT", "b2", "b3", "b4 EDIT", "b5" })

    local tabpage, session, explorer = open_explorer("b.txt")
    assert.is_not_nil(session)
    local first_file = explorer.data.current_file_path

    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { session.stored_diff_result.changes[1].modified.start_line, 0 })

    nav.prev_hunk()
    assert.is_true(wait_for_file_switch(tabpage, first_file))

    local new_session = lifecycle.get_session(tabpage)
    local last_change = new_session.stored_diff_result.changes[#new_session.stored_diff_result.changes]
    local last_modified = last_change.modified.start_line
    local last_original = last_change.original.start_line
    -- Sanity: the two line numbers must actually diverge for this test to
    -- be meaningful. If they're equal, the bug wouldn't manifest.
    assert.is_true(last_modified ~= last_original, "test scaffold: modified and original line numbers must diverge (got both = " .. last_modified .. ")")

    local cursor_after = vim.api.nvim_win_get_cursor(new_session.modified_win)[1]
    assert.equal(last_modified, cursor_after, "cursor must land on the MODIFIED-side last-hunk line (" .. last_modified .. "), not the original-side (" .. last_original .. ")")
  end)

  it("issue #479: EOF deletions use the last valid line and cross-file cycling advances", function()
    config.options.diff.cycle_hunks_across_files = true

    -- The modified side ends immediately before the deletion hunk's raw start
    -- line. The hunk is reported as modified [4, 4), while line 3 is the last
    -- cursor position that exists in the buffer.
    repo.write_file("a.txt", { "a1", "a2", "a3" })

    local tabpage, session, explorer = open_explorer("a.txt", 1)
    assert.is_not_nil(session)
    assert.is_not_nil(explorer)
    assert.equal(3, vim.api.nvim_win_get_cursor(session.modified_win)[1], "EOF deletion should land on the last valid modified line")

    local first_file = explorer.data.current_file_path
    nav.next_hunk()
    assert.is_true(wait_for_file_switch(tabpage, first_file), "next hunk should advance past the EOF deletion")
    assert.equal("b.txt", explorer.data.current_file_path)

    local next_session = lifecycle.get_session(tabpage)
    local first_hunk_line = next_session.stored_diff_result.changes[1].modified.start_line
    assert.equal(first_hunk_line, vim.api.nvim_win_get_cursor(next_session.modified_win)[1])

    nav.prev_hunk()
    assert.is_true(wait_for_file_switch(tabpage, "b.txt"), "previous hunk should return to the EOF deletion")
    local previous_session = lifecycle.get_session(tabpage)
    assert.equal("a.txt", explorer.data.current_file_path)
    assert.equal(3, vim.api.nvim_win_get_cursor(previous_session.modified_win)[1], "backward landing should clamp the EOF deletion")
  end)
end)
