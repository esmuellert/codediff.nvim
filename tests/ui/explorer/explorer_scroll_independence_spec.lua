-- Regression: the explorer pane must NOT scroll together with the side-by-side
-- diff panes. Native scrollbind is enabled only on the diff windows.

local h = dofile("tests/helpers.lua")

-- Ensure plugin is loaded (registers the :CodeDiff command for the subprocess).
h.ensure_plugin_loaded()

local function setup_command()
  local commands = require("codediff.commands")
  vim.api.nvim_create_user_command("CodeDiff", function(opts)
    commands.vscode_diff(opts)
  end, { nargs = "*", bang = true })
end

-- Repo with a long first file (so the diff panes can scroll a lot) plus many
-- small changed files (so the explorer list is longer than the window and can
-- itself scroll). Returns the repo handle.
local function busy_repo()
  local repo = h.create_temp_git_repo()
  local long = {}
  for i = 1, 200 do
    long[i] = string.format("line %03d", i)
  end
  repo.write_file("file01.txt", long)
  for n = 2, 40 do
    repo.write_file(string.format("file%02d.txt", n), { "a", "b" })
  end
  repo.git("add -A")
  repo.git('commit -m "initial"')
  local longmod = vim.deepcopy(long)
  longmod[5] = "CHANGED 005"
  longmod[150] = "CHANGED 150"
  repo.write_file("file01.txt", longmod)
  for n = 2, 40 do
    repo.write_file(string.format("file%02d.txt", n), { "A", "b" })
  end
  return repo
end

local function open_codediff_and_wait(repo, timeout_ms)
  timeout_ms = timeout_ms or 12000
  vim.fn.chdir(repo.dir)
  vim.cmd("edit " .. repo.path("file01.txt"))
  vim.cmd("CodeDiff")
  local lifecycle = require("codediff.ui.lifecycle")
  local tabpage
  -- Wait until the diff content has loaded and native scrollbind is enabled
  -- (both happen asynchronously after :CodeDiff).
  local ready = vim.wait(timeout_ms, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local s = lifecycle.get_session(tp)
      if s and (s.panel or {}).view and s.original_win and s.modified_win and vim.api.nvim_win_is_valid(s.original_win) and vim.api.nvim_win_is_valid(s.modified_win) then
        local mbuf = vim.api.nvim_win_get_buf(s.modified_win)
        if vim.api.nvim_buf_is_valid(mbuf) and vim.api.nvim_buf_line_count(mbuf) > 100 and vim.wo[s.original_win].scrollbind and vim.wo[s.modified_win].scrollbind then
          tabpage = tp
          return true
        end
      end
    end
    return false
  end, 100)
  assert.is_true(ready, "CodeDiff explorer, loaded diff panes, and native scrollbind should be ready")
  local session = lifecycle.get_session(tabpage)
  return tabpage, session, (session.panel or {}).view
end

local function topline(win)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.line("w0")
  end)
end

describe("explorer scroll independence", function()
  local repo
  local original_cwd
  before_each(function()
    require("codediff").setup()
    setup_command()
    original_cwd = vim.fn.getcwd()
  end)
  after_each(function()
    pcall(function()
      while vim.fn.tabpagenr("$") > 1 do
        vim.cmd("tabclose!")
      end
    end)
    -- Restore cwd BEFORE deleting the temp repo. open_codediff_and_wait chdir's
    -- into repo.dir; if we delete it while cwd is still inside, the next test's
    -- git/mkdir subprocesses fail with getcwd errors (E739) in CI.
    vim.fn.chdir(original_cwd)
    if repo then
      repo.cleanup()
      repo = nil
    end
  end)

  it("keeps the explorer out of native scrollbind", function()
    repo = busy_repo()
    local _, session, explorer = open_codediff_and_wait(repo)
    assert.is_not_nil(explorer and explorer.winid, "explorer window should exist")
    assert.is_true(vim.wo[session.original_win].scrollbind, "original diff pane should use native scrollbind")
    assert.is_true(vim.wo[session.modified_win].scrollbind, "modified diff pane should use native scrollbind")
    assert.is_false(vim.wo[explorer.winid].scrollbind, "explorer must not have native scrollbind")
  end)

  it("does not move the explorer when the diff panes scroll", function()
    repo = busy_repo()
    local _, session, explorer = open_codediff_and_wait(repo)
    local explorer_top_before = topline(explorer.winid)
    local orig_top_before = topline(session.original_win)

    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { 1, 0 })
    for _ = 1, 80 do
      vim.cmd("normal! \5") -- <C-e>
    end
    vim.cmd("redraw")

    assert.is_true(topline(session.modified_win) > 20, "modified diff pane should have scrolled down")
    -- The other diff pane DOES follow (sync is live)...
    assert.is_true(topline(session.original_win) > orig_top_before, "original diff pane should follow (sync live)")
    -- ...but the explorer must stay put.
    assert.are.equal(explorer_top_before, topline(explorer.winid), "explorer must stay put while the diff panes scroll")
  end)

  it("does not move the diff panes when the explorer scrolls", function()
    repo = busy_repo()
    local _, session, explorer = open_codediff_and_wait(repo)

    -- Move the diff to a non-top position first.
    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { 1, 0 })
    for _ = 1, 40 do
      vim.cmd("normal! \5")
    end
    vim.cmd("redraw")
    local mod_top = topline(session.modified_win)
    local orig_top = topline(session.original_win)

    -- Scroll the explorer; the diff panes must not move.
    vim.api.nvim_set_current_win(explorer.winid)
    vim.api.nvim_win_set_cursor(explorer.winid, { 1, 0 })
    for _ = 1, 20 do
      vim.cmd("normal! \5")
    end
    vim.cmd("redraw")

    assert.are.equal(mod_top, topline(session.modified_win), "modified diff pane must stay put while the explorer scrolls")
    assert.are.equal(orig_top, topline(session.original_win), "original diff pane must stay put while the explorer scrolls")
  end)
end)
