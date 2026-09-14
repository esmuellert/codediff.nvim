-- Test: Welcome page after git operations (commit, stash)
-- Validates that diff panes show welcome page when all changes are resolved.
--
-- Staging/unstaging E2E tests are in hunk_operations_spec.lua (keymap-driven).
-- These tests cover commit and stash operations that remove files from the tree.

local h = dofile("tests/helpers.lua")

-- Ensure plugin is loaded (needed when the test framework isolates specs)
h.ensure_plugin_loaded()

-- Setup CodeDiff command for tests
local function setup_command()
  local commands = require("codediff.commands")
  vim.api.nvim_create_user_command("CodeDiff", function(opts)
    commands.vscode_diff(opts)
  end, {
    nargs = "*",
    bang = true,
    complete = function()
      return { "file", "install" }
    end,
  })
end

--- Trigger an explorer refresh and wait for the async git-status +
--- vim.schedule callback to propagate.
--- @param explorer table  The explorer object from lifecycle
--- @param timeout_ms? number  How long to spin (default 3000)
local function refresh_and_wait(explorer, timeout_ms)
  timeout_ms = timeout_ms or 3000
  require("codediff.ui.refresh").request(explorer.tabpage, { full = true })
  -- The refresh is async (git status → vim.schedule). We must let the
  -- event loop run so the callback fires and the tree / session update.
  vim.wait(timeout_ms, function()
    return false -- just spin, processing the event loop
  end, 50)
end

--- Open :CodeDiff in the given repo directory and wait until the explorer
--- is fully ready (session exists, explorer is set, diff buffers loaded).
--- Returns tabpage, session, explorer.
--- @param repo table  Repo helper from h.create_temp_git_repo()
--- @return number tabpage
--- @return table session
--- @return table explorer
local function open_codediff_and_wait(repo)
  vim.fn.chdir(repo.dir)
  -- Open a file so CodeDiff has context
  vim.cmd("edit " .. repo.path("file1.txt"))
  vim.cmd("CodeDiff")

  local lifecycle = require("codediff.ui.lifecycle")
  local tabpage

  local ready = vim.wait(10000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local s = lifecycle.get_session(tp)
      if s and (s.panel or {}).view then
        tabpage = tp
        local orig_buf, mod_buf = lifecycle.get_buffers(tp)
        if orig_buf and mod_buf then
          return vim.api.nvim_buf_is_valid(orig_buf) and vim.api.nvim_buf_is_valid(mod_buf)
        end
      end
    end
    return false
  end, 100)

  assert.is_true(ready, "CodeDiff explorer and diff panes should be ready")

  local session = lifecycle.get_session(tabpage)
  local explorer = (session.panel or {}).view
  assert.is_not_nil(explorer, "Explorer should exist on session")

  return tabpage, session, explorer
end

--- Count the total number of file entries across all groups in the tree.
--- @param explorer table
--- @return number
local function count_tree_files(explorer)
  local files = require("codediff.ui.explorer.tree").get_all_files(explorer.tree)
  return #files
end

--- Check whether a file path exists in any group of the explorer tree.
--- @param explorer table
--- @param path string  Relative file path
--- @return boolean
local function file_exists_in_tree(explorer, path)
  local files = require("codediff.ui.explorer.tree").get_all_files(explorer.tree)
  for _, f in ipairs(files) do
    if f.data.path == path then
      return true
    end
  end
  return false
end

-- ============================================================================
describe("Welcome Page After Git Operations", function()
  local repo
  local original_cwd

  before_each(function()
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    setup_command()
    original_cwd = vim.fn.getcwd()

    -- Create temp git repo with two modified files
    repo = h.create_temp_git_repo()

    -- file1.txt: committed, then modified (unstaged)
    repo.write_file("file1.txt", { "line1", "line2", "line3" })
    repo.git("add file1.txt")
    repo.git('commit -m "add file1"')
    repo.write_file("file1.txt", { "line1", "modified line2", "line3" })

    -- file2.txt: committed, then modified (unstaged)
    repo.write_file("file2.txt", { "alpha", "beta", "gamma" })
    repo.git("add file2.txt")
    repo.git('commit -m "add file2"')
    repo.write_file("file2.txt", { "alpha", "modified beta", "gamma" })
  end)

  after_each(function()
    -- Safe cleanup: create fresh tab, close all others
    pcall(function()
      vim.cmd("tabnew")
      vim.cmd("tabonly")
    end)
    vim.fn.chdir(original_cwd)
    vim.wait(200)
    if repo then
      repo.cleanup()
    end
  end)

  -- --------------------------------------------------------------------------
  -- Test: Commit current file — others remain, welcome if empty
  -- --------------------------------------------------------------------------
  it("shows welcome or next file when current file is committed", function()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")
    local welcome = require("codediff.ui.welcome")

    -- Precondition: file1.txt selected in unstaged
    assert.equals("file1.txt", explorer.data.current_file_path, "Precondition: should be viewing file1.txt")

    -- Commit only file1.txt
    repo.git("add file1.txt")
    repo.git('commit -m "commit file1"')

    refresh_and_wait(explorer)

    -- file1.txt should be gone from the tree
    assert.is_false(file_exists_in_tree(explorer, "file1.txt"), "file1.txt should be removed from explorer after commit")

    -- file2.txt should still be present
    assert.is_true(file_exists_in_tree(explorer, "file2.txt"), "file2.txt should still be in explorer tree")

    -- The diff panes should NOT show stale file1.txt content.
    -- They should either show welcome (if nothing auto-selected)
    -- or show a different file.
    session = lifecycle.get_session(tabpage)
    local shows_welcome = welcome.is_welcome_buffer(session.modified_bufnr)
    local shows_different_file = explorer.data.current_file_path ~= "file1.txt"
    assert.is_true(shows_welcome or shows_different_file, "After committing file1: should show welcome or a different file, not stale file1 content")
  end)

  -- --------------------------------------------------------------------------
  -- Test 6: Commit everything — welcome page shows
  -- --------------------------------------------------------------------------
  it("shows welcome page when all files are committed", function()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")
    local welcome = require("codediff.ui.welcome")

    -- Commit everything
    repo.git("add -A")
    repo.git('commit -m "commit all"')

    refresh_and_wait(explorer)

    -- Explorer tree should have zero files
    assert.equals(0, count_tree_files(explorer), "Explorer tree should have 0 files after committing everything")

    -- Diff panes should show the welcome page
    session = lifecycle.get_session(tabpage)
    assert.is_true(welcome.is_welcome_buffer(session.modified_bufnr), "Welcome buffer should be shown after committing all files")
    assert.is_nil(explorer.data.current_file_path, "Current file path should be cleared when the tree becomes empty")
    assert.is_nil(explorer.data.current_file_group, "Current file group should be cleared when the tree becomes empty")
  end)

  -- --------------------------------------------------------------------------
  -- Test 7: Stash all changes — welcome page shows
  -- --------------------------------------------------------------------------
  it("shows welcome page when all changes are stashed", function()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")
    local welcome = require("codediff.ui.welcome")

    -- Stash everything
    repo.git("stash")

    refresh_and_wait(explorer)

    -- Explorer tree should have zero files
    assert.equals(0, count_tree_files(explorer), "Explorer tree should have 0 files after stashing all changes")

    -- Diff panes should show the welcome page
    session = lifecycle.get_session(tabpage)
    assert.is_true(welcome.is_welcome_buffer(session.modified_bufnr), "Welcome buffer should be shown after stashing all changes")
    assert.is_nil(explorer.data.current_file_path, "Current file path should be cleared when the tree becomes empty")
    assert.is_nil(explorer.data.current_file_group, "Current file group should be cleared when the tree becomes empty")
  end)
end)
