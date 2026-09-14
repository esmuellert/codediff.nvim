-- End-to-end coverage of the :CodeDiff command grammars. Each case triggers the
-- real command in a real temp git repo and asserts the actual rendered result
-- (diff buffer contents, explorer file list, history commits, layout) — not just
-- that dispatch routed correctly.
--
-- Scope note: the headless test runner cannot drive the async codediff:// virtual-file
-- load (git-show for a revision) — a diff whose original is a git *revision*
-- opens a tab but never finishes registering its session under the test runner
-- (it works fine interactively; see scripts/nvim-e2e.lua). So the git-revision
-- single-file diffs (`file HEAD`, `file <rev> <rev>`) and 3-way `merge` are not
-- asserted here; their dispatch is covered by tests/core/argparse_spec.lua and
-- the command-parity differential. The single-file diff *render* and the layout
-- flags are still covered below using two real files (no virtual buffer).

local h = dofile("tests/helpers.lua")
local lifecycle = require("codediff.ui.lifecycle")
local commands = require("codediff.commands")

describe("Command E2E (real dispatch + render)", function()
  local repo
  local hash1, hash2
  local original_cwd = vim.fn.getcwd() -- restored in after_each so temp-repo cleanup can't strand cwd (E739)

  local function setup_command()
    vim.api.nvim_create_user_command("CodeDiff", function(opts)
      commands.vscode_diff(opts)
    end, { nargs = "*", bang = true, range = true })
  end

  local function find_explorer_buf()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tp)) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "codediff-explorer" then
          return buf
        end
      end
    end
  end

  local function find_explorer_tab()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tp)) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "codediff-explorer" then
          return tp
        end
      end
    end
  end

  local function explorer_text(timeout)
    vim.wait(timeout or 10000, function()
      return find_explorer_buf() ~= nil
    end, 50)
    local buf = find_explorer_buf()
    assert.is_not_nil(buf, "an explorer window should open")
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  local function session_tabs()
    local out = {}
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      if lifecycle.get_session(tp) then
        out[#out + 1] = tp
      end
    end
    return out
  end

  -- Wait for a diff session (real-file diff) whose buffers contain `text`.
  local function wait_for_diff_text(text, timeout)
    local found
    vim.wait(timeout or 10000, function()
      for _, tp in ipairs(session_tabs()) do
        local o, m = lifecycle.get_buffers(tp)
        for _, b in ipairs({ o, m }) do
          if b and vim.api.nvim_buf_is_valid(b) then
            if table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find(text, 1, true) then
              found = tp
              return true
            end
          end
        end
      end
      return false
    end, 50)
    return found
  end

  local function all_visible_text()
    local chunks = {}
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tp)) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_buf_is_valid(buf) then
          table.insert(chunks, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
        end
      end
    end
    return table.concat(chunks, "\n")
  end

  local function wait_for_visible(text, timeout)
    return vim.wait(timeout or 10000, function()
      return all_visible_text():find(text, 1, true) ~= nil
    end, 50)
  end

  before_each(function()
    setup_command()
    repo = h.create_temp_git_repo()
    repo.write_file("file.txt", { "line 1", "line 2", "line 3" })
    repo.git("add file.txt")
    repo.git("commit -m c1")
    hash1 = vim.trim((repo.git("rev-parse HEAD")))
    repo.write_file("file.txt", { "line 1", "line 2 CHANGED", "line 3" })
    repo.git("add file.txt")
    repo.git("commit -m c2")
    hash2 = vim.trim((repo.git("rev-parse HEAD")))
    repo.write_file("a.txt", { "alpha content", "shared" })
    repo.write_file("b.txt", { "beta content", "shared" })
    vim.cmd("edit " .. repo.path("file.txt"))
  end)

  after_each(function()
    for _, tp in ipairs(session_tabs()) do
      pcall(lifecycle.close, tp)
    end
    vim.wait(150)
    vim.cmd("silent! tabnew")
    vim.cmd("silent! tabonly")
    vim.cmd("silent! enew")
    vim.wait(100)
    -- Some tests do `:lcd <repo>`; leave that directory BEFORE deleting it so
    -- the next before_each's mkdir/getcwd doesn't fail on Linux (E739).
    pcall(vim.cmd, "silent! cd " .. vim.fn.fnameescape(original_cwd))
    if repo then
      repo.cleanup()
    end
  end)

  -- ── Explorer family ───────────────────────────────────────────────────────

  it(":CodeDiff — explorer lists working-tree changes", function()
    repo.write_file("file.txt", { "line 1", "line 2 WORKING", "line 3" })
    vim.cmd("edit! " .. repo.path("file.txt"))
    vim.cmd("CodeDiff")
    h.assert_contains(explorer_text(), "file.txt", "explorer lists file.txt")
  end)

  it(":CodeDiff HEAD~1 — explorer against a revision", function()
    vim.cmd("CodeDiff HEAD~1")
    h.assert_contains(explorer_text(), "file.txt")
  end)

  it(":CodeDiff <rev1> <rev2> — explorer comparing two revisions", function()
    vim.cmd("CodeDiff " .. hash1 .. " " .. hash2)
    h.assert_contains(explorer_text(), "file.txt")
  end)

  it(":CodeDiff main... — merge-base explorer shows only branch changes", function()
    repo.git("checkout -b feature " .. hash1)
    repo.write_file("feature.txt", { "feature work" })
    repo.git("add feature.txt")
    repo.git("commit -m feat")
    vim.cmd("CodeDiff main...")
    h.assert_contains(explorer_text(), "feature.txt")
  end)

  -- ── Staged-only mode (--staged / --cached, #352) ──────────────────────────

  it(":CodeDiff --staged — shows only files with staged changes", function()
    -- Stage a change to file.txt so it's the only entry with staged changes.
    repo.write_file("file.txt", { "line 1", "line 2 STAGED", "line 3" })
    repo.git("add file.txt")
    -- Unstaged-only edit to a.txt: must NOT appear under --staged.
    repo.write_file("a.txt", { "alpha WORKING", "shared" })
    vim.cmd("edit! " .. repo.path("file.txt"))
    vim.cmd("CodeDiff --staged")
    local text = explorer_text()
    h.assert_contains(text, "Staged Changes", "explorer group is labeled 'Staged Changes'")
    h.assert_contains(text, "file.txt", "staged file is listed")
    assert.is_nil(text:find("a.txt", 1, true), "unstaged-only file is hidden")
  end)

  it(":CodeDiff --cached — alias of --staged", function()
    repo.write_file("file.txt", { "line 1", "line 2 STAGED", "line 3" })
    repo.git("add file.txt")
    vim.cmd("CodeDiff --cached")
    h.assert_contains(explorer_text(), "Staged Changes")
  end)

  it(":CodeDiff --staged <rev> — compares index against the given revision", function()
    -- Stage new content differing from BOTH HEAD and HEAD~1.
    repo.write_file("file.txt", { "line 1", "line 2 STAGED", "line 3" })
    repo.git("add file.txt")
    vim.cmd("CodeDiff --staged HEAD~1")
    local text = explorer_text()
    h.assert_contains(text, "Staged Changes")
    h.assert_contains(text, "file.txt")
    -- Verify the explorer is in staged-only mode via its own state (session
    -- revisions are set lazily on file click; the explorer object records
    -- them at open time).
    local tab = find_explorer_tab()
    assert.is_not_nil(tab)
    local session = lifecycle.get_session(tab)
    assert.is_not_nil(session)
    local explorer = (session.panel or {}).view
    assert.is_not_nil(explorer)
    assert.equals(":0", explorer.data.target_revision, "the comparison target is the index (:0)")
    assert.is_not_nil(explorer.data.base_revision, "the comparison base resolves to HEAD~1")
  end)

  it(":CodeDiff --staged with no staged changes — notifies gracefully", function()
    local notified
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.INFO then
        notified = tostring(msg)
      end
    end
    vim.cmd("CodeDiff --staged")
    vim.wait(2000, function()
      return notified ~= nil
    end)
    vim.notify = orig_notify
    assert.is_not_nil(notified)
    h.assert_contains(notified, "No staged changes")
  end)

  -- ── Single-file diff (two real files) ─────────────────────────────────────

  it(":CodeDiff file <a> <b> — renders both files in a diff", function()
    vim.cmd("CodeDiff file " .. repo.path("a.txt") .. " " .. repo.path("b.txt"))
    local tab = wait_for_diff_text("beta")
    assert.is_not_nil(tab, "modified pane should show b.txt")
    local orig = lifecycle.get_buffers(tab)
    h.assert_contains(h.get_buffer_content(orig), "alpha", "original pane shows a.txt")
  end)

  -- ── Directory diff ────────────────────────────────────────────────────────

  it(":CodeDiff dir <d1> <d2> — explorer lists differing files", function()
    repo.write_file("dirA/x.txt", { "A" })
    repo.write_file("dirB/x.txt", { "B" })
    vim.cmd("CodeDiff dir " .. repo.path("dirA") .. " " .. repo.path("dirB"))
    h.assert_contains(explorer_text(), "x.txt")
  end)

  -- ── History ───────────────────────────────────────────────────────────────

  it(":CodeDiff history — shows the commit log", function()
    vim.cmd("CodeDiff history")
    assert.is_true(wait_for_visible("c2"), "history shows commit subjects")
  end)

  it(":CodeDiff history % — history for the current file", function()
    vim.cmd("edit! " .. repo.path("file.txt"))
    vim.cmd("CodeDiff history %")
    assert.is_true(wait_for_visible("c1"), "history shows a commit that touched the file")
  end)

  it(":CodeDiff history --reverse — accepts flags", function()
    vim.cmd("CodeDiff history --reverse")
    assert.is_true(wait_for_visible("c1"))
  end)

  it("visual line history works from an active diff buffer (#463)", function()
    vim.cmd("CodeDiff --inline file " .. repo.path("a.txt") .. " " .. repo.path("file.txt"))
    local diff_tab = wait_for_diff_text("line 2 CHANGED")
    assert.is_not_nil(diff_tab, "inline diff should open")

    local diff_session = lifecycle.get_session(diff_tab)
    assert.is_not_nil(diff_session)
    vim.api.nvim_set_current_tabpage(diff_tab)
    vim.api.nvim_set_current_win(diff_session.modified_win)
    local modified_buf = diff_session.modified_bufnr
    vim.api.nvim_buf_set_mark(modified_buf, "<", 1, 0, {})
    vim.api.nvim_buf_set_mark(modified_buf, ">", 2, 0, {})

    vim.cmd("'<,'>CodeDiff history")

    local history_tab
    assert.is_true(
      vim.wait(10000, function()
        for _, tp in ipairs(session_tabs()) do
          local session = lifecycle.get_session(tp)
          if session.panel and session.panel.name == "history" then
            history_tab = tp
            return true
          end
        end
        return false
      end, 50),
      "visual line history should open a history session"
    )

    local history_session = lifecycle.get_session(history_tab)
    assert.is_not_nil(history_session.panel.view)
    assert.are.same({ 1, 2 }, history_session.panel.data.opts.line_range)
    assert.equals("file.txt", history_session.panel.data.opts.file_path)
    assert.is_true(wait_for_visible("c1"), "history should show commits for the selected lines")
  end)

  -- ── Layout flags (on a real-file diff) ────────────────────────────────────

  it(":CodeDiff --inline file <a> <b> — inline layout", function()
    vim.cmd("CodeDiff --inline file " .. repo.path("a.txt") .. " " .. repo.path("b.txt"))
    local tab = wait_for_diff_text("beta")
    assert.is_not_nil(tab)
    assert.equals("inline", lifecycle.get_session(tab).layout, "layout is inline")
  end)

  it(":CodeDiff --side-by-side file <a> <b> — side-by-side layout", function()
    vim.cmd("CodeDiff --side-by-side file " .. repo.path("a.txt") .. " " .. repo.path("b.txt"))
    local tab = wait_for_diff_text("beta")
    assert.is_not_nil(tab)
    assert.equals("side-by-side", lifecycle.get_session(tab).layout)
  end)

  -- ── --repo / -C (operate on another repository) ──────────────────────────

  it(":CodeDiff --repo <path> — explorer targets another repository", function()
    local repo2 = h.create_temp_git_repo()
    repo2.write_file("only-in-2.txt", { "x" })
    repo2.git("add only-in-2.txt")
    repo2.git("commit -m base2")
    repo2.write_file("only-in-2.txt", { "x changed" })
    local text = ""
    local ok = pcall(function()
      vim.cmd("CodeDiff --repo " .. repo2.dir)
      text = explorer_text()
    end)
    repo2.cleanup()
    assert.is_true(ok)
    h.assert_contains(text, "only-in-2.txt", "explorer shows the other repo's file")
    assert.is_nil(text:find("file.txt", 1, true), "does not show the current repo's file")
  end)

  it(":CodeDiff -C <path> history — history for another repository", function()
    local repo2 = h.create_temp_git_repo()
    repo2.write_file("r2.txt", { "y" })
    repo2.git("add r2.txt")
    repo2.git("commit -m only-repo2-commit")
    local shown
    pcall(function()
      vim.cmd("CodeDiff -C " .. repo2.dir .. " history")
      shown = wait_for_visible("only-repo2-commit")
    end)
    repo2.cleanup()
    assert.is_true(shown, "history shows the other repo's commit")
  end)

  it(":CodeDiff --repo <non-repo> — reports a clear error", function()
    local notified
    local orig = vim.notify
    vim.notify = function(msg)
      notified = tostring(msg)
    end
    vim.cmd("CodeDiff --repo /tmp/codediff-not-a-repo-" .. tostring(vim.loop.now()))
    vim.wait(3000, function()
      return notified ~= nil
    end)
    vim.notify = orig
    assert.is_not_nil(notified)
    h.assert_contains(notified, "Not a git repository", "notifies a clear error")
  end)

  -- ── Pathspec filtering (-- <path>, issue #74) ─────────────────────────────

  it(":CodeDiff <rev1> <rev2> -- <subdir> — filters the file list to that subtree", function()
    -- Two subtrees both change between v1 and v2; the pathspec keeps only one.
    repo.write_file("modules/net/n.txt", { "n" })
    repo.write_file("modules/store/s.txt", { "s" })
    repo.git("add -A")
    repo.git("commit -m v1")
    repo.git("tag v1")
    repo.write_file("modules/net/n.txt", { "n changed" })
    repo.write_file("modules/store/s.txt", { "s changed" })
    repo.git("add -A")
    repo.git("commit -m v2")
    repo.git("tag v2")
    vim.cmd("CodeDiff v1 v2 -- modules/net")
    local text = explorer_text()
    h.assert_contains(text, "n.txt", "shows files under modules/net")
    assert.is_nil(text:find("s.txt", 1, true), "hides files outside the pathspec")
  end)

  it(":CodeDiff -- <subdir> — filters working-tree status to that subtree", function()
    repo.write_file("modules/net/n.txt", { "n" })
    repo.write_file("modules/store/s.txt", { "s" })
    repo.git("add -A")
    repo.git("commit -m base")
    repo.write_file("modules/net/n.txt", { "n changed" }) -- working change under net
    repo.write_file("modules/store/s.txt", { "s changed" }) -- working change under store
    vim.cmd("CodeDiff -- modules/net")
    local text = explorer_text()
    h.assert_contains(text, "n.txt", "shows working changes under modules/net")
    assert.is_nil(text:find("s.txt", 1, true), "hides working changes outside the pathspec")
  end)

  it(":CodeDiff --repo <other> -- <subdir> — pathspec composes with --repo", function()
    local repo2 = h.create_temp_git_repo()
    repo2.write_file("app/a.txt", { "a" })
    repo2.write_file("lib/b.txt", { "b" })
    repo2.git("add -A")
    repo2.git("commit -m base2")
    repo2.write_file("app/a.txt", { "a changed" })
    repo2.write_file("lib/b.txt", { "b changed" })
    local text = ""
    pcall(function()
      vim.cmd("CodeDiff --repo " .. repo2.dir .. " -- app")
      text = explorer_text()
    end)
    repo2.cleanup()
    h.assert_contains(text, "a.txt", "shows the other repo's files under app/")
    assert.is_nil(text:find("b.txt", 1, true), "hides files outside the pathspec in the other repo")
  end)

  it(":CodeDiff -- <subdir> — auto-refresh keeps the pathspec scope (#74 regression)", function()
    -- Regression: an auto-refresh (BufEnter / .git watcher) used to re-run git
    -- WITHOUT the pathspec, silently widening the file list back to the whole repo.
    repo.write_file("modules/net/n.txt", { "n" })
    repo.write_file("modules/store/s.txt", { "s" })
    repo.git("add -A")
    repo.git("commit -m base")
    repo.write_file("modules/net/n.txt", { "n changed" }) -- change under net (in scope)
    repo.write_file("modules/store/s.txt", { "s changed" }) -- change under store (out of scope)

    vim.cmd("CodeDiff -- modules/net")
    local text = explorer_text()
    h.assert_contains(text, "n.txt", "initial open shows files under modules/net")
    assert.is_nil(text:find("s.txt", 1, true), "initial open hides files outside the pathspec")

    -- Add a fresh out-of-scope change AND an in-scope one, then force a refresh
    -- through the real code path. Waiting on the in-scope marker guarantees the
    -- async refresh actually completed before we assert on scope.
    repo.write_file("modules/store/s2.txt", { "s2" })
    repo.write_file("modules/net/n2.txt", { "n2" })
    local explorer = lifecycle.get_panel_view(find_explorer_tab())
    require("codediff.ui.refresh").request(explorer.tabpage, { full = true })

    local refreshed = vim.wait(10000, function()
      local buf = find_explorer_buf()
      return buf ~= nil and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("n2.txt", 1, true) ~= nil
    end, 50)
    assert.is_true(refreshed, "refresh picks up the new in-scope file (n2.txt)")

    local after = table.concat(vim.api.nvim_buf_get_lines(find_explorer_buf(), 0, -1, false), "\n")
    assert.is_nil(after:find("s.txt", 1, true), "refresh still hides the out-of-scope file (s.txt)")
    assert.is_nil(after:find("s2.txt", 1, true), "refresh does not surface a new out-of-scope file (s2.txt)")
  end)

  -- ── Completion ────────────────────────────────────────────────────────────

  it("completion offers subcommands and git refs", function()
    vim.cmd("lcd " .. repo.dir)
    local cands = commands.complete("", "CodeDiff ")
    for _, name in ipairs({ "file", "dir", "history", "pr", "merge", "install" }) do
      assert.is_true(vim.tbl_contains(cands, name), "offers subcommand " .. name)
    end
    assert.is_true(vim.tbl_contains(cands, "HEAD"), "offers HEAD ref")
    assert.is_true(vim.tbl_contains(commands.complete("--r", "CodeDiff --r"), "--repo"), "offers --repo flag")
    assert.is_true(vim.tbl_contains(commands.complete("", "CodeDiff pr "), "clean"), "offers PR cleanup")
    assert.is_true(vim.tbl_contains(commands.complete("--r", "CodeDiff pr 12 --r"), "--remote"), "offers PR remote flag")
    assert.is_true(vim.tbl_contains(commands.complete("--b", "CodeDiff pr 12 --b"), "--base"), "offers PR base flag")
    assert.is_true(vim.tbl_contains(commands.complete("--a", "CodeDiff pr clean --a"), "--all"), "offers cleanup all flag")
    assert.is_false(vim.tbl_contains(commands.complete("-a", "CodeDiff pr clean -a"), "-a"), "does not offer a short cleanup alias")
    assert.is_false(vim.tbl_contains(commands.complete("", "CodeDiff pr 12 -- "), "HEAD"), "PR path scope excludes revisions")
  end)

  it("completion after -- offers file paths, not subcommands or refs (#74)", function()
    vim.cmd("lcd " .. repo.dir)
    repo.write_file("modules/net/n.txt", { "n" })
    local cands = commands.complete("modules/", "CodeDiff -- modules/")
    assert.is_true(table.concat(cands, "\n"):find("modules/net", 1, true) ~= nil, "offers a path under modules/")
    assert.is_false(vim.tbl_contains(cands, "file"), "does not offer subcommands after --")
    assert.is_false(vim.tbl_contains(cands, "HEAD"), "does not offer git refs after --")
  end)
end)
