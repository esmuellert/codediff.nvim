-- Regression: leaving conflict mode must tear down the result pane.
--
-- In merge/conflict mode a file is shown in three panes (incoming | current on
-- top, result below). Navigating (]f / [f) to an untracked or deleted file
-- renders a single-pane view, which used to close only the unused input pane
-- and leave the result window behind. The stale pane stayed under the new file,
-- and returning to the conflict file reused that window -- whose buffer still
-- holds unsaved merge edits -- so `:edit` failed with E37 "No write since last
-- change" and the result pane never came back.

local h = require("tests.support")
local path = require("codediff.core.path")

describe("conflict mode single-file switching", function()
  local repo
  local tabpage
  local notify_errors
  local saved_notify

  local function conflict_config()
    return {
      git_root = repo.dir,
      original = path.make_ref("conf.txt", repo.dir),
      modified = path.make_ref("conf.txt", repo.dir),
      original_revision = ":3",
      modified_revision = ":2",
      conflict = true,
    }
  end

  local function result_window()
    local _, rw = require("codediff.ui.lifecycle").get_result(tabpage)
    if rw and vim.api.nvim_win_is_valid(rw) then
      return rw
    end
    return nil
  end

  -- Open the conflict view and wait for its three panes to exist.
  local function open_conflict_view()
    local view = require("codediff.ui.view")
    local lifecycle = require("codediff.ui.lifecycle")

    vim.cmd("edit " .. repo.dir .. "/conf.txt")
    local ready = false
    view.create(conflict_config(), "", function()
      ready = true
    end)
    assert.is_true(
      vim.wait(15000, function()
        return ready
      end, 50),
      "conflict view.create did not become ready"
    )

    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local s = lifecycle.get_session(tp)
      if s and s.result_bufnr then
        tabpage = tp
        break
      end
    end
    assert.is_not_nil(tabpage, "a conflict session should exist")
    assert.is_not_nil(result_window(), "conflict view should have a result window")
  end

  -- Return to the conflict view the way ]f/[f does, via view.update.
  local function reopen_conflict_view()
    require("codediff.ui.view").update(tabpage, conflict_config(), false)
    vim.wait(15000, function()
      return result_window() ~= nil
    end, 50)
  end

  before_each(function()
    h.ensure_plugin_loaded()
    tabpage = nil
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

    repo.write_file("fresh.txt", { "n1", "n2" })

    notify_errors = {}
    saved_notify = vim.notify
    vim.notify = function(msg, level, opts)
      if type(msg) == "string" and msg:find("Failed to open result file", 1, true) then
        notify_errors[#notify_errors + 1] = msg
        return
      end
      return saved_notify(msg, level, opts)
    end
  end)

  after_each(function()
    if saved_notify then
      vim.notify = saved_notify
      saved_notify = nil
    end
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    if repo then
      repo.cleanup()
      repo = nil
    end
  end)

  it("closes the result pane when an untracked file replaces the conflict view", function()
    open_conflict_view()

    require("codediff.ui.view.side_by_side").show_untracked_file(tabpage, repo.path("fresh.txt"))

    assert.is_nil(result_window(), "result pane must not survive into the single-file view")
  end)

  it("restores the conflict view without error after showing a single file", function()
    open_conflict_view()
    require("codediff.ui.view.side_by_side").show_untracked_file(tabpage, repo.path("fresh.txt"))
    assert.is_nil(result_window(), "result pane must be gone while the single file is shown")

    reopen_conflict_view()

    assert.are.same({}, notify_errors, "returning to the conflict file must not fail to open the result file")
    assert.is_not_nil(result_window(), "conflict result pane must be restored")
  end)

  it("keeps the result buffer loaded so merge edits are not discarded", function()
    open_conflict_view()
    local result_bufnr = select(1, require("codediff.ui.lifecycle").get_result(tabpage))
    assert.is_not_nil(result_bufnr)

    require("codediff.ui.view.side_by_side").show_untracked_file(tabpage, repo.path("fresh.txt"))

    assert.is_true(vim.api.nvim_buf_is_valid(result_bufnr), "result buffer must stay valid")
    assert.is_true(vim.api.nvim_buf_is_loaded(result_bufnr), "result buffer must only be hidden, never unloaded")
  end)
end)
