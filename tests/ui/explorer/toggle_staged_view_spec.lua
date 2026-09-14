-- Regression tests for https://github.com/esmuellert/codediff.nvim/issues/352
--
-- `toggle_staged_view` swaps between the staged and unstaged view of the
-- currently reviewed file. Only meaningful in Status Mode; a no-op in
-- revision, directory, or --staged modes.

local h = dofile("tests/helpers.lua")

describe("toggle_staged_view (issue #352)", function()
  local repo
  local lifecycle = require("codediff.ui.lifecycle")
  local actions = require("codediff.ui.explorer.actions")

  before_each(function()
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    lifecycle.cleanup_all()

    repo = h.create_temp_git_repo()
    -- Two files present in HEAD.
    repo.write_file("both.txt", { "original both" })
    repo.write_file("only_staged.txt", { "original only_staged" })
    repo.git("add .")
    repo.git("commit -m initial")

    -- `both.txt`: stage one change, then add another unstaged one — it now
    -- lives in BOTH the staged and unstaged groups.
    repo.write_file("both.txt", { "staged change" })
    repo.git("add both.txt")
    repo.write_file("both.txt", { "staged change", "unstaged follow-up" })

    -- `only_staged.txt`: staged-only edit — no unstaged counterpart.
    repo.write_file("only_staged.txt", { "staged-only edit" })
    repo.git("add only_staged.txt")
  end)

  after_each(function()
    h.close_extra_tabs()
    lifecycle.cleanup_all()
    if repo then
      repo.cleanup()
    end
  end)

  local function open_status_explorer(focus_rel)
    vim.cmd("edit " .. repo.path(focus_rel))
    require("codediff.commands").vscode_diff({ fargs = {} })
    local explorer
    local ready = vim.wait(8000, function()
      for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
        local sess = lifecycle.get_session(tp)
        if sess and (sess.panel or {}).view and (sess.panel or {}).view.data.current_file_path ~= nil then
          explorer = (sess.panel or {}).view
          return true
        end
      end
      return false
    end, 50)
    return ready, explorer
  end

  it("swaps a dual-group file from unstaged to staged", function()
    local ready, explorer = open_status_explorer("both.txt")
    assert.is_true(ready, "explorer opens with a selection")
    assert.is_true(vim.wait(3000, function()
      return explorer.data.current_file_path == "both.txt" and explorer.data.current_file_group == "unstaged"
    end, 50), "initial selection is both.txt/unstaged")

    local ok = actions.toggle_staged_view(explorer)
    assert.is_true(ok, "toggle succeeds when file exists in both groups")
    assert.equals("both.txt", explorer.data.current_file_path)
    assert.equals("staged", explorer.data.current_file_group)
  end)

  it("swaps back to unstaged on a second toggle", function()
    local ready, explorer = open_status_explorer("both.txt")
    assert.is_true(ready)
    vim.wait(500)
    actions.toggle_staged_view(explorer)
    assert.equals("staged", explorer.data.current_file_group)
    actions.toggle_staged_view(explorer)
    assert.equals("unstaged", explorer.data.current_file_group)
  end)

  it("notifies and stays put when the file has no counterpart", function()
    -- Manually force selection to only_staged.txt/staged and then try to swap
    -- to unstaged — no unstaged counterpart exists.
    local ready, explorer = open_status_explorer("only_staged.txt")
    assert.is_true(ready)
    -- Force the selection into the staged group.
    explorer.on_file_select({
      path = "only_staged.txt",
      old_path = nil,
      status = "M",
      git_root = explorer.data.git_root,
      group = "staged",
    })
    assert.is_true(vim.wait(2000, function()
      return explorer.data.current_file_group == "staged"
    end, 50))

    local notified
    local orig = vim.notify
    vim.notify = function(msg, level)
      notified = tostring(msg)
    end
    local ok = actions.toggle_staged_view(explorer)
    vim.notify = orig

    assert.is_false(ok, "toggle refuses when the sibling group is empty")
    assert.equals("staged", explorer.data.current_file_group, "selection is unchanged")
    assert.is_not_nil(notified)
    h.assert_contains(notified, "No unstaged changes")
  end)

  it("refuses in --staged mode (no other side to swap to)", function()
    vim.cmd("edit " .. repo.path("both.txt"))
    require("codediff.commands").vscode_diff({ fargs = { "--staged" } })
    local explorer
    assert.is_true(vim.wait(8000, function()
      for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
        local sess = lifecycle.get_session(tp)
        if sess and (sess.panel or {}).view then
          explorer = (sess.panel or {}).view
          return true
        end
      end
      return false
    end, 50))
    -- Verify we're in staged-only mode.
    assert.equals(":0", explorer.data.target_revision, "explorer is in staged-only mode")

    local notified
    local orig = vim.notify
    vim.notify = function(msg, level)
      notified = tostring(msg)
    end
    local ok = actions.toggle_staged_view(explorer)
    vim.notify = orig

    assert.is_false(ok, "toggle refuses in --staged mode")
    assert.is_not_nil(notified)
    h.assert_contains(notified, "Status Mode")
  end)

  it("refuses in revision mode (:CodeDiff HEAD)", function()
    vim.cmd("edit " .. repo.path("both.txt"))
    require("codediff.commands").vscode_diff({ fargs = { "HEAD" } })
    local explorer
    assert.is_true(vim.wait(8000, function()
      for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
        local sess = lifecycle.get_session(tp)
        if sess and (sess.panel or {}).view then
          explorer = (sess.panel or {}).view
          return true
        end
      end
      return false
    end, 50))
    assert.is_not_nil(explorer.data.base_revision, "explorer is in revision mode")

    local notified
    local orig = vim.notify
    vim.notify = function(msg, level)
      notified = tostring(msg)
    end
    local ok = actions.toggle_staged_view(explorer)
    vim.notify = orig

    assert.is_false(ok)
    assert.is_not_nil(notified)
  end)
end)
