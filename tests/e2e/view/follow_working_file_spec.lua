-- Following the working window's file.
--
-- With one side of a diff pinned to a git revision and the other showing the
-- working file, opening a different file in the working window re-targets the
-- whole diff at it. Implemented by ui/follow_working_file.lua, which installs a
-- BufWinEnter listener on that window.
--
-- The feature had broken silently before — a session field was renamed and
-- defeated the listener's change guard, with nothing to catch it — so these
-- pin down the behaviour rather than the implementation.

local helpers = require("tests.support")

describe("following the working file", function()
  local repo

  before_each(function()
    repo = helpers.create_temp_git_repo()
    repo.write_file("alpha.txt", { "alpha one", "alpha two", "alpha three" })
    repo.write_file("beta.txt", { "beta one", "beta two", "beta three" })
    repo.git("add -A")
    repo.git("commit -qm initial")
    -- Both files differ from HEAD so either one produces a real diff.
    repo.write_file("alpha.txt", { "alpha one CHANGED", "alpha two", "alpha three" })
    repo.write_file("beta.txt", { "beta one", "beta two CHANGED", "beta three" })
  end)

  after_each(function()
    helpers.close_extra_tabs()
    if repo then
      repo.cleanup()
    end
  end)

  --- Open `:CodeDiff file HEAD` on `rel` and return its tabpage.
  --- `layout_flag` picks the layout, e.g. "--inline".
  local function open_file_diff(rel, layout_flag)
    vim.cmd("edit " .. repo.path(rel))
    vim.cmd("CodeDiff file HEAD" .. (layout_flag and (" " .. layout_flag) or ""))
    local ok = vim.wait(10000, function()
      local s = require("codediff.ui.lifecycle").get_session(vim.api.nvim_get_current_tabpage())
      return s ~= nil and s.stored_diff_result ~= nil and s.modified_win ~= nil
    end, 50)
    assert.is_true(ok, "diff view never became ready")
    return vim.api.nvim_get_current_tabpage()
  end

  --- Absolute path the session currently has on its modified (working) side.
  local function modified_path(tabpage)
    local sess = require("codediff.ui.lifecycle").get_session(tabpage)
    return sess and sess.modified and sess.modified.absolute or nil
  end

  it("re-targets the diff when the working window edits another file", function()
    local tabpage = open_file_diff("alpha.txt")
    local lifecycle = require("codediff.ui.lifecycle")
    local sess = lifecycle.get_session(tabpage)

    helpers.assert_contains(modified_path(tabpage), "alpha.txt", "should start on alpha.txt")

    -- Switch the working pane to the other file, the way a user would.
    vim.api.nvim_set_current_win(sess.modified_win)
    vim.cmd("edit " .. repo.path("beta.txt"))

    local switched = vim.wait(10000, function()
      local p = modified_path(tabpage)
      return p ~= nil and p:find("beta.txt", 1, true) ~= nil
    end, 50)

    assert.is_true(switched, "diff should have re-targeted to beta.txt, got: " .. tostring(modified_path(tabpage)))
  end)

  it("brings the original side along, so the diff is beta vs HEAD:beta", function()
    local tabpage = open_file_diff("alpha.txt")
    local lifecycle = require("codediff.ui.lifecycle")
    local sess = lifecycle.get_session(tabpage)

    vim.api.nvim_set_current_win(sess.modified_win)
    vim.cmd("edit " .. repo.path("beta.txt"))

    vim.wait(10000, function()
      local p = modified_path(tabpage)
      return p ~= nil and p:find("beta.txt", 1, true) ~= nil
    end, 50)

    -- The original pane must now hold HEAD:beta.txt, not the stale alpha
    -- content, otherwise the panes would be showing two different files.
    -- view.update() swaps the original buffer, so re-read it every poll rather
    -- than holding the pre-switch id.
    local ok = vim.wait(5000, function()
      local s = lifecycle.get_session(tabpage)
      local bufnr = s and s.original_bufnr
      if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return false
      end
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      return table.concat(lines, "\n"):find("beta one", 1, true) ~= nil
    end, 50)

    local final = lifecycle.get_session(tabpage)
    local final_buf = final and final.original_bufnr
    local shown = (final_buf and vim.api.nvim_buf_is_valid(final_buf)) and helpers.get_buffer_content(final_buf) or "<no valid original buffer>"
    assert.is_true(ok, "original pane should show HEAD:beta.txt, got: " .. shown)
  end)

  it("ignores buffers entering other windows", function()
    local tabpage = open_file_diff("alpha.txt")
    local lifecycle = require("codediff.ui.lifecycle")
    local sess = lifecycle.get_session(tabpage)
    local before = modified_path(tabpage)

    -- A buffer entering a window that is not the working pane must not
    -- re-target anything.
    vim.api.nvim_set_current_win(sess.original_win)
    vim.cmd("split " .. repo.path("beta.txt"))
    vim.wait(800)

    assert.equals(before, modified_path(tabpage), "editing outside the working window must not re-target")
  end)

  it("follows the working file in the inline layout too", function()
    -- The listener used to be installed only by the side-by-side path, so the
    -- same `:CodeDiff file <rev>` session silently stopped following once it
    -- was opened (or toggled) inline.
    local tabpage = open_file_diff("alpha.txt", "--inline")
    local lifecycle = require("codediff.ui.lifecycle")
    local sess = lifecycle.get_session(tabpage)

    assert.equals("inline", sess.layout, "expected an inline session")
    helpers.assert_contains(modified_path(tabpage), "alpha.txt", "should start on alpha.txt")

    vim.api.nvim_set_current_win(sess.modified_win)
    vim.cmd("edit " .. repo.path("beta.txt"))

    local switched = vim.wait(10000, function()
      local p = modified_path(tabpage)
      return p ~= nil and p:find("beta.txt", 1, true) ~= nil
    end, 50)

    assert.is_true(switched, "inline diff should re-target to beta.txt, got: " .. tostring(modified_path(tabpage)))
  end)
end)
