-- Two independent explorer regressions, both fixed in the file-refresh path.
--
-- 1. External working-tree changes must refresh without requiring focus. The
--    native watcher provides this normally; serialized polling remains the
--    startup and runtime fallback.
--
-- 2. Single-file resize reset: untracked/added/deleted files render in a single
--    pane via show_single_file. A refresh re-selects the open file; real
--    two-pane diffs short-circuit that, but the single-file statuses rebuilt
--    the window every time and the layout pass discarded any manual sizing.
--    show_single_file now skips the rebuild when nothing changed.
--
-- Split from tests/ui/explorer/explorer_spec.lua so the two describe blocks
-- (one for open/layout, one for refresh) can run as independent workers under
-- the framework's per-file parallelism.

local config = require("codediff.config")
local h = dofile("tests/helpers.lua")

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

describe("Explorer refresh and single-file stability", function()
  local temp_dir
  local original_cwd
  local original_get_panel_view
  local original_get_status_with_line_stats

  local function open(focus_file)
    local lifecycle = require("codediff.ui.lifecycle")
    lifecycle.cleanup_all()
    vim.cmd("edit " .. temp_dir .. "/" .. focus_file)
    vim.cmd("CodeDiff")
    local tabpage, explorer
    local ready = vim.wait(10000, function()
      for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
        local e = lifecycle.get_panel_view(tp)
        if e and e.winid and vim.api.nvim_win_is_valid(e.winid) then
          tabpage, explorer = tp, e
          return true
        end
      end
      return false
    end, 50)
    assert.is_true(ready, "explorer should open")
    return tabpage, explorer
  end

  local function select_and_settle(explorer, path, status, group, opts)
    explorer.on_file_select({ path = path, status = status, group = group, git_root = temp_dir }, opts or {})
    vim.wait(2500, function()
      return false
    end)
  end

  local function single_win(tabpage)
    local lifecycle = require("codediff.ui.lifecycle")
    local s = lifecycle.get_session(tabpage)
    if s.original_win and vim.api.nvim_win_is_valid(s.original_win) then
      return s.original_win
    end
    if s.modified_win and vim.api.nvim_win_is_valid(s.modified_win) then
      return s.modified_win
    end
  end

  before_each(function()
    config.options = vim.deepcopy(config.defaults)
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    setup_command()
    original_cwd = vim.fn.getcwd()
    temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
    vim.fn.chdir(temp_dir)
    h.git_cmd(temp_dir, "init")
    h.git_cmd(temp_dir, "branch -m main")
    h.git_cmd(temp_dir, 'config user.email "test@example.com"')
    h.git_cmd(temp_dir, 'config user.name "Test User"')
    vim.fn.writefile({ "line 1", "line 2" }, temp_dir .. "/file1.txt")
    h.git_cmd(temp_dir, "add file1.txt")
    h.git_cmd(temp_dir, 'commit -m "initial"')
    -- file1.txt modified (unstaged), file3.txt untracked
    vim.fn.writefile({ "line 1", "line 2 modified" }, temp_dir .. "/file1.txt")
    vim.fn.writefile({ "untracked" }, temp_dir .. "/file3.txt")
  end)

  after_each(function()
    if original_get_panel_view then
      require("codediff.ui.lifecycle").get_panel_view = original_get_panel_view
      original_get_panel_view = nil
    end
    if original_get_status_with_line_stats then
      require("codediff.core.git").get_status_with_line_stats = original_get_status_with_line_stats
      original_get_status_with_line_stats = nil
    end
    require("codediff.ui.lifecycle").cleanup_all()
    vim.cmd("tabnew")
    vim.cmd("tabonly")
    vim.fn.chdir(original_cwd)
    vim.wait(200)
    if temp_dir and vim.fn.isdirectory(temp_dir) == 1 then
      vim.fn.delete(temp_dir, "rf")
    end
  end)

  it("drops a refresh result when the explorer no longer owns the tab", function()
    config.options.explorer.auto_refresh = false
    local tabpage, explorer = open("file1.txt")
    local lifecycle = require("codediff.ui.lifecycle")
    local git = require("codediff.core.git")
    local refresh = require("codediff.ui.explorer.refresh")
    local status_before = vim.deepcopy(explorer.status_result)
    local git_callback
    local completed = 0

    original_get_status_with_line_stats = git.get_status_with_line_stats
    git.get_status_with_line_stats = function(_, callback)
      git_callback = callback
    end
    refresh.refresh(explorer, function()
      completed = completed + 1
    end)
    assert.is_true(vim.wait(1000, function()
      return type(git_callback) == "function"
    end, 10))

    original_get_panel_view = lifecycle.get_panel_view
    lifecycle.get_panel_view = function(candidate)
      assert.equals(tabpage, candidate)
      return nil
    end
    git_callback(nil, {
      unstaged = {
        { path = "file1.txt", status = "M" },
        { path = "new.txt", status = "??" },
      },
      staged = {},
      conflicts = {},
    })

    assert.is_true(vim.wait(1000, function()
      return not lifecycle.get_session(tabpage).refresh.running
    end, 10))
    assert.equals(0, completed, "a retired panel must not replay navigation callbacks")
    assert.same(status_before, explorer.status_result)
  end)

  it("picks up an externally-created untracked file automatically", function()
    -- The test suite disables native asset installation, so this also proves
    -- that serialized polling remains a functional fallback.
    local _, explorer = open("file1.txt")

    -- External change: brand-new untracked file, no nvim buffer, no BufEnter.
    vim.fn.writefile({ "hello from outside" }, temp_dir .. "/brand_new.txt")

    -- Wait for automatic refresh to observe the new working-tree state.
    local picked_up = vim.wait(3000, function()
      for _, f in ipairs((explorer.status_result or {}).unstaged or {}) do
        if f.path == "brand_new.txt" then
          return true
        end
      end
      return false
    end, 100)
    assert.is_true(picked_up, "external file must appear in the explorer without focus")
  end)

  it("reloads the current diff when an invalidation leaves status unchanged", function()
    local tabpage, explorer = open("file1.txt")
    local lifecycle = require("codediff.ui.lifecycle")
    explorer.on_file_select({ path = "file1.txt", status = "M", group = "unstaged", git_root = temp_dir }, { force = true })
    local selected = vim.wait(10000, function()
      local session = lifecycle.get_session(tabpage)
      if not session or not session.modified_bufnr or not vim.api.nvim_buf_is_valid(session.modified_bufnr) then
        return false
      end
      return vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)[2] == "line 2 modified"
    end, 50)
    assert.is_true(selected, "the initial working-tree buffer should load")
    local before_status = vim.deepcopy(explorer.status_result)

    vim.fn.writefile({ "line 1", "changed again" }, temp_dir .. "/file1.txt")
    explorer._request_auto_refresh()

    local updated = vim.wait(5000, function()
      local session = lifecycle.get_session(tabpage)
      if not session or not session.modified_bufnr or not vim.api.nvim_buf_is_valid(session.modified_bufnr) then
        return false
      end
      return vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)[2] == "changed again"
    end, 50)
    assert.is_true(updated, "the visible working-tree buffer should reload")
    assert.same(before_status, explorer.status_result, "the Git status remained unchanged")
  end)

  it("keeps a manually resized single-file pane across a refresh", function()
    local tabpage, explorer = open("file1.txt")
    select_and_settle(explorer, "file3.txt", "??", "unstaged", { force = true })

    local win = single_win(tabpage)
    assert.is_not_nil(win, "untracked file should be shown in a single pane")
    local width = vim.api.nvim_win_get_width(win) - 10
    vim.api.nvim_win_call(win, function()
      vim.cmd("vertical resize " .. width)
    end)
    assert.are.equal(width, vim.api.nvim_win_get_width(win), "resize should apply")

    -- A refresh re-selects the file that is already open.
    select_and_settle(explorer, "file3.txt", "??", "unstaged")

    assert.are.equal(width, vim.api.nvim_win_get_width(single_win(tabpage)), "manual pane size must survive a refresh")
  end)

  it("still re-renders a single-file view when the file's status changes", function()
    local tabpage, explorer = open("file1.txt")
    select_and_settle(explorer, "file3.txt", "??", "unstaged", { force = true })
    local before = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(single_win(tabpage)))

    -- Staging turns ?? into A, shown from the index (:0) rather than the working
    -- tree, so the view must rebuild rather than be skipped.
    h.git_cmd(temp_dir, "add file3.txt")
    select_and_settle(explorer, "file3.txt", "A", "staged")

    local after = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(single_win(tabpage)))
    assert.are_not.equal(before, after, "staged view must come from a different buffer than the working-tree view")
  end)

  it("still restores both panes when returning to a real diff", function()
    local tabpage, explorer = open("file1.txt")
    select_and_settle(explorer, "file3.txt", "??", "unstaged", { force = true })
    assert.is_not_nil(single_win(tabpage), "should be in single-pane mode")

    select_and_settle(explorer, "file1.txt", "M", "unstaged", { force = true })

    local lifecycle = require("codediff.ui.lifecycle")
    local s = lifecycle.get_session(tabpage)
    assert.is_true(
      s.original_win ~= nil and vim.api.nvim_win_is_valid(s.original_win) and s.modified_win ~= nil and vim.api.nvim_win_is_valid(s.modified_win),
      "returning to a modified file must restore both diff panes"
    )
  end)
end)
