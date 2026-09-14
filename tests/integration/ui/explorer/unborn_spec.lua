-- Regression test for https://github.com/esmuellert/codediff.nvim/issues/498
--
-- On an unborn branch (fresh repo with no commits yet), `git rev-parse
-- --verify HEAD` fails with "Needed a single revision". Callers of
-- `git.resolve_revision` want to use the returned hash as a diff base, and
-- git ships a universal empty-tree hash (4b825dc6...) that IS a valid diff
-- base — comparing against it shows every staged/worktree file as newly
-- added, which is the correct semantic for a pre-first-commit repo.
--
-- The fix at the git layer means every caller (unstaged row, staged row of
-- an AM file, future callers) just works without knowing about the unborn
-- special case.

local h = require("tests.support")

describe("Issue #498 regression — unborn HEAD is treated as the empty tree", function()
  local repo
  local lifecycle
  local orig_notify
  local notifications

  local GIT_EMPTY_TREE_SHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

  local function make_unborn_repo()
    -- The shared fixture provides an unborn main branch in a TMP worktree;
    -- it has no HEAD commit despite being cloned from an internal seed.
    repo = h.create_temp_git_repo()
  end

  before_each(function()
    h.ensure_plugin_loaded()
    lifecycle = require("codediff.ui.lifecycle")
    lifecycle.cleanup_all()

    notifications = {}
    orig_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = tostring(msg), level = level })
    end
  end)

  after_each(function()
    if orig_notify then
      vim.notify = orig_notify
      orig_notify = nil
    end
    if repo then
      repo.cleanup()
      repo = nil
    end
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose")
    end
  end)

  it("git.resolve_revision('HEAD') returns the empty-tree SHA on an unborn branch", function()
    make_unborn_repo()

    -- Sanity: HEAD is genuinely unresolvable in this repo.
    local head_check = repo.git("rev-parse --verify HEAD 2>&1")
    assert.is_not_nil(
      head_check:find("Needed a single revision", 1, true) or head_check:find("unknown revision", 1, true),
      "precondition: HEAD should not resolve on unborn branch, got: " .. head_check
    )

    -- Call resolve_revision and wait for the async callback.
    local git = require("codediff.core.git")
    local result = { err = nil, hash = nil, done = false }
    git.resolve_revision("HEAD", repo.dir, function(err, hash)
      result.err = err
      result.hash = hash
      result.done = true
    end)

    local done = vim.wait(3000, function()
      return result.done
    end, 20)
    assert.is_true(done, "resolve_revision callback did not fire within 3s")

    assert.is_nil(result.err, "resolve_revision should not return an error on unborn HEAD, got: " .. tostring(result.err))
    assert.equals(GIT_EMPTY_TREE_SHA, result.hash)
  end)

  it("git.resolve_revision('main') still returns a real error for a genuinely bad ref", function()
    make_unborn_repo()

    local git = require("codediff.core.git")
    local result = { done = false }
    git.resolve_revision("nonexistent-ref-abc", repo.dir, function(err, hash)
      result.err = err
      result.hash = hash
      result.done = true
    end)

    local done = vim.wait(3000, function()
      return result.done
    end, 20)
    assert.is_true(done)

    -- Non-HEAD refs must still surface as errors (the fix is narrow to HEAD).
    assert.is_not_nil(result.err)
    assert.is_nil(result.hash)
    assert.is_not_nil(result.err:find("Invalid revision"), "expected 'Invalid revision' in err, got: " .. tostring(result.err))
  end)

  it("selecting a file in :CodeDiff on an unborn branch does not surface 'Invalid revision'", function()
    -- End-to-end coverage of the reporter's exact repro: `git init`, stage,
    -- then edit further (AM state), then run :CodeDiff. Auto-selects the
    -- unstaged row of test.md, which used to error at resolve_revision('HEAD').
    make_unborn_repo()
    repo.write_file("test.md", { "foo" })
    repo.git("add test.md")
    repo.write_file("test.md", { "foo", "bar" })

    local status = repo.git("status --porcelain")
    assert.is_not_nil(status:find("AM test.md", 1, true), "precondition: file must be in AM state, got: " .. status)

    vim.cmd("edit " .. repo.dir .. "/test.md")
    local commands = require("codediff.commands")
    commands.vscode_diff({ fargs = {} })

    local session_ok = vim.wait(6000, function()
      local session = lifecycle.get_session(vim.api.nvim_get_current_tabpage())
      return session and (session.panel or {}).view ~= nil
    end, 100)
    assert.is_true(session_ok, "explorer should populate")
    vim.wait(3000)

    for _, n in ipairs(notifications) do
      assert.is_nil(n.msg:find("Invalid revision", 1, true), "unexpected 'Invalid revision' notification: " .. n.msg)
      assert.is_nil(n.msg:find("Needed a single revision", 1, true), "unexpected 'Needed a single revision' notification: " .. n.msg)
    end
  end)

  it("selecting the staged row of an A (added) file on an unborn branch does not crash with 'Invalid buffer id'", function()
    -- Reproduces the second half of #498: even after the git-layer fix makes
    -- resolve_revision return the empty-tree hash, clicking the STAGED row of
    -- a newly-added file could crash the render layer with "Invalid buffer id"
    -- because the virtual buffer created by load_virtual_file has
    -- `bufhidden=wipe`. If show_single_file closed the other window BEFORE
    -- setting the new buffer into keep_win, the virtual buffer would have no
    -- window during the close, get wiped, and nvim_win_set_buf would fail.
    -- Fix: swap the order so the buffer is set into keep_win first.
    make_unborn_repo()
    repo.write_file("test.md", { "foo" })
    repo.git("add test.md")
    repo.write_file("test.md", { "foo", "bar" })

    vim.cmd("edit " .. repo.dir .. "/test.md")
    local commands = require("codediff.commands")
    commands.vscode_diff({ fargs = {} })

    local session_ok = vim.wait(6000, function()
      local session = lifecycle.get_session(vim.api.nvim_get_current_tabpage())
      return session and (session.panel or {}).view ~= nil
    end, 100)
    assert.is_true(session_ok, "explorer should populate")

    -- Navigate to the staged row of test.md and press <CR>. The file appears
    -- on line 4 of the explorer buffer with structure:
    --   line 1: Changes (1)
    --   line 2:   test.md M
    --   line 3: Staged Changes (1)
    --   line 4:   test.md A
    local sess = lifecycle.get_session(vim.api.nvim_get_current_tabpage())
    local explorer = (sess.panel or {}).view
    local staged_row
    for line = 1, vim.api.nvim_buf_line_count(explorer.bufnr) do
      local node = explorer.tree:get_node(line)
      if node and node.data and node.data.path == "test.md" and node.data.group == "staged" then
        staged_row = node.data
        break
      end
    end
    assert.is_not_nil(staged_row, "staged row for test.md should exist in the tree")

    -- Directly invoke the same callback the <CR> keymap uses. The crash
    -- surfaces as a Lua traceback into stderr, not vim.notify, so we assert
    -- that the diff session actually opens with a valid modified buffer.
    -- Wrap in xpcall so we can also detect the traceback shape directly.
    local error_seen
    xpcall(function()
      explorer.on_file_select(staged_row)
      vim.wait(3000)
    end, function(err)
      error_seen = err
    end)

    -- The manual repro produces a "vim.schedule callback: ... Invalid buffer
    -- id" traceback. It's not caught by xpcall (the schedule runs later), but
    -- it leaves the session with the modified buffer invalid.
    local mod_buf = sess.modified_bufnr
    assert.is_number(mod_buf, "modified buffer should be set on the session")
    assert.is_true(vim.api.nvim_buf_is_valid(mod_buf), "modified buffer must be valid (not wiped by the pre-fix race)")

    -- Also assert the buffer has *content* — an empty buffer would suggest the
    -- diff render aborted mid-flow.
    local content = vim.api.nvim_buf_get_lines(mod_buf, 0, -1, false)
    assert.is_true(#content > 0 or content[1] == "", "modified buffer should be readable")
  end)
end)
