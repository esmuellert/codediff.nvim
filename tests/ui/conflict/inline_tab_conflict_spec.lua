-- A conflicted file forces the side-by-side layout, but the tab may still be
-- shaped for inline: one pane, both sides pointing at it. side_by_side.update
-- then wrote both into that window, THEIRS overwriting OURS, and never opened
-- the result pane. :CodeDiff was fine; it goes through create.

local h = dofile("tests/helpers.lua")

describe("conflicted file in an inline tab", function()
  local repo, saved_layout

  before_each(function()
    h.ensure_plugin_loaded()
    local config = require("codediff.config")
    saved_layout = config.options.diff.layout
    config.options.diff.layout = "inline"

    repo = h.create_temp_git_repo()
    repo.write_file("conf.txt", { "base1", "base2", "base3" })
    repo.git("add -A")
    repo.git("commit -m base")
    repo.git("checkout -b feature")
    repo.write_file("conf.txt", { "FEATURE1", "base2", "base3" })
    repo.git("commit -am feature")
    repo.git("checkout main")
    repo.write_file("conf.txt", { "MAIN1", "base2", "base3" })
    repo.git("commit -am main")
    local merge_out = repo.git("merge feature --no-edit")
    assert.is_true(merge_out:find("CONFLICT", 1, true) ~= nil, "merge must conflict")
  end)

  after_each(function()
    require("codediff.config").options.diff.layout = saved_layout
    if repo then
      repo.cleanup()
    end
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
  end)

  it("opens the three-pane merge view, not a single pane", function()
    local lifecycle = require("codediff.ui.lifecycle")
    local path = require("codediff.core.path")

    vim.cmd("edit " .. repo.path("conf.txt"))
    vim.cmd("CodeDiff --inline")
    assert.is_true(
      vim.wait(15000, function()
        return h.find_window_by_filetype("codediff-explorer") ~= nil
      end, 50),
      "inline explorer never opened"
    )

    local tabpage = vim.api.nvim_get_current_tabpage()
    assert.equals("inline", lifecycle.get_session(tabpage).layout, "tab should start out inline")

    -- Same config the explorer builds for a file in the Merge Changes group,
    -- including which side lands on the left: conflict_ours_position decides,
    -- and it defaults to putting OURS on the right.
    local ours_position = require("codediff.config").options.diff.conflict_ours_position or "right"
    local left_rev = ours_position == "right" and ":3" or ":2"
    local right_rev = ours_position == "right" and ":2" or ":3"
    local left_text = ours_position == "right" and "FEATURE1" or "MAIN1"
    local right_text = ours_position == "right" and "MAIN1" or "FEATURE1"

    require("codediff.ui.view").update(tabpage, {
      git_root = repo.dir,
      original = path.make_ref("conf.txt", repo.dir),
      modified = path.make_ref("conf.txt", repo.dir),
      original_revision = left_rev,
      modified_revision = right_rev,
      conflict = true,
    }, false)

    -- The result pane appears before the two sides finish loading, so wait for
    -- content rather than for the window.
    assert.is_true(
      vim.wait(15000, function()
        local s = lifecycle.get_session(tabpage)
        if not (s and s.result_win and vim.api.nvim_win_is_valid(s.result_win)) then
          return false
        end
        if not (s.original_win and s.modified_win and vim.api.nvim_win_is_valid(s.original_win) and vim.api.nvim_win_is_valid(s.modified_win)) then
          return false
        end
        local o = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(s.original_win), 0, -1, false)
        local m = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(s.modified_win), 0, -1, false)
        return table.concat(o, "\n"):find(left_text, 1, true) ~= nil and table.concat(m, "\n"):find(right_text, 1, true) ~= nil
      end, 50),
      "conflicted file must open a result pane with both sides loaded"
    )

    local session = lifecycle.get_session(tabpage)

    -- Both sides need their own window, or one overwrites the other.
    assert.is_not_nil(session.original_win, "OURS needs a window")
    assert.is_not_nil(session.modified_win, "THEIRS needs a window")
    assert.not_equal(session.original_win, session.modified_win, "the two sides must not share a window")
    for _, win in ipairs({ session.original_win, session.modified_win, session.result_win }) do
      assert.is_true(vim.wo[win].scrollbind, "all conflict panes should use native scrollbind")
    end

    local ours = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(session.original_win), 0, -1, false)
    local theirs = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(session.modified_win), 0, -1, false)
    h.assert_contains(table.concat(ours, "\n"), left_text, "left pane holds the wrong side")
    h.assert_contains(table.concat(theirs, "\n"), right_text, "right pane holds the wrong side")
  end)
end)
