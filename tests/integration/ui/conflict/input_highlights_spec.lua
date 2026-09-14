-- Regression test for https://github.com/esmuellert/codediff.nvim/issues/387
-- In conflict mode, both input panes must show changes with the same green
-- "added relative to BASE" highlight (matches VSCode's
-- mergeEditor.change.background) — and that coloring must survive any
-- TextChanged-like event without being overwritten by the normal diff
-- renderer's red/green scheme.

local h = require('tests.support')
local path = require("codediff.core.path")

describe('Issue #387 regression — conflict-mode input panes stay green on TextChanged', function()
  local repo

  before_each(function()
    h.ensure_plugin_loaded()
    repo = h.create_temp_git_repo()
  end)

  after_each(function()
    if repo then repo.cleanup() end
    while vim.fn.tabpagenr('$') > 1 do
      vim.cmd('tabclose')
    end
  end)

  it('both input panes use LineInsert (green) and survive TextChanged', function()
    repo.write_file('file.txt', { "line 1", "line 2", "line 3", "line 4", "line 5" })
    repo.git("add file.txt")
    repo.git("commit -m c0")

    repo.git("checkout -b feature")
    repo.write_file('file.txt', { "line 1", "line 2", "line 3 (feature)", "line 4", "line 5" })
    repo.git("commit -am feature")

    repo.git("checkout main")
    repo.write_file('file.txt', { "line 1", "line 2", "line 3 (main)", "line 4", "line 5" })
    repo.git("commit -am main")

    local merge_out = repo.git("merge feature --no-edit")
    assert.is_true(merge_out:find("CONFLICT", 1, true) ~= nil, "merge must conflict")

    -- Open codediff in conflict mode using the same session_config shape
    -- the :CodeDiff merge command (and neogit's integration) builds.
    vim.cmd("edit " .. repo.dir .. "/file.txt")
    local view = require("codediff.ui.view")
    local ready = false
    view.create({
      git_root = repo.dir,
      original = path.make_ref("file.txt", repo.dir),
      modified = path.make_ref("file.txt", repo.dir),
      original_revision = ":3",
      modified_revision = ":2",
      conflict = true,
    }, "", function() ready = true end)

    assert.is_true(vim.wait(15000, function() return ready end, 50),
      "view.create did not become ready")

    local lifecycle = require("codediff.ui.lifecycle")
    local sess
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local s = lifecycle.get_session(tp)
      if s and s.result_bufnr then sess = s; break end
    end
    assert.is_not_nil(sess)

    local highlights = require("codediff.ui.highlights")
    local function counts(bufnr)
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, highlights.ns_highlight, 0, -1, { details = true })
      local g = {}
      for _, m in ipairs(marks) do
        local d = m[4] or {}
        if d.hl_group then g[d.hl_group] = (g[d.hl_group] or 0) + 1 end
      end
      return g
    end

    local function assert_green_only(g, label)
      assert.is_true((g.CodeDiffLineInsert or 0) > 0,
        label .. " must have CodeDiffLineInsert highlights, got: " .. vim.inspect(g))
      assert.equal(0, g.CodeDiffLineDelete or 0,
        label .. " must NOT have CodeDiffLineDelete (red); VSCode uses one color for both inputs. Got: "
          .. vim.inspect(g))
      assert.equal(0, g.CodeDiffCharDelete or 0,
        label .. " must NOT have CodeDiffCharDelete. Got: " .. vim.inspect(g))
    end

    -- Initial render must paint both panes green (matches VSCode).
    assert_green_only(counts(sess.original_bufnr), "ORIGINAL (incoming/theirs) initial")
    assert_green_only(counts(sess.modified_bufnr), "MODIFIED (current/ours) initial")

    -- Fire TextChanged on both input buffers (simulates user clicking into
    -- them, plugin decorating, etc.). Pre-fix, this triggered auto_refresh
    -- which overwrote ORIGINAL with CodeDiffLineDelete (red). Post-fix the
    -- panes must keep the same green coloring.
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = sess.original_bufnr, modeline = false })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = sess.modified_bufnr, modeline = false })
    vim.wait(500)

    assert_green_only(counts(sess.original_bufnr), "ORIGINAL (incoming/theirs) after TextChanged")
    assert_green_only(counts(sess.modified_bufnr), "MODIFIED (current/ours) after TextChanged")
  end)
end)
