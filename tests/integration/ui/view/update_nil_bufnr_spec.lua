-- Regression test for #592: a scheduled render can run re-entrantly while
-- show() is still loading the other side. When the virtual side's content
-- arrives from the (warm) git cache, readiness queues render_everything with
-- vim.schedule; a vim.wait inside an LspAttach handler during the real
-- side's :edit (yaml-companion's request_sync does exactly this) pumps that
-- queue before open_real_file has returned, so modified_info.bufnr is still
-- nil and nvim_buf_is_valid(nil) throws at update.lua:210. The view must
-- render anyway once both sides are loaded, not crash and stay unrendered.
--
-- The vim.wait in the FileType autocmd below stands in for yaml-companion:
-- no real LSP server is needed, only a handler that pumps the event loop
-- while :edit is running.

local support = require("tests.support")
local path = require("codediff.core.path")
local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")

describe("side-by-side update with a nil bufnr (#592)", function()
  local repo, sha, tab

  local function config_for(file)
    return {
      git_root = repo.dir,
      original = path.make_ref(file, repo.dir),
      modified = path.make_ref(file, repo.dir),
      original_revision = sha,
      modified_revision = "WORKING",
    }
  end

  local function diff_ready()
    local session = tab and lifecycle.get_session(tab)
    local result = session and session.stored_diff_result
    return result ~= nil and result.changes ~= nil and #result.changes > 0
  end

  before_each(function()
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    support.ensure_plugin_loaded()
    repo = support.create_temp_git_repo()
    repo.write_file("config.yaml", { "key: one", "list:", "  - a", "  - b" })
    repo.write_file("other.yaml", { "name: one", "v: 1" })
    sha = repo.commit("add yamls")
    repo.write_file("config.yaml", { "key: two", "list:", "  - a", "  - b", "  - c" })
    repo.write_file("other.yaml", { "name: two", "v: 2" })
  end)

  after_each(function()
    pcall(vim.api.nvim_clear_autocmds, { group = "CodeDiff592Repro" })
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    if repo then
      repo.cleanup()
      repo = nil
    end
    tab = nil
  end)

  it("renders the diff instead of crashing when a scheduled render runs while the real side is still loading", function()
    -- Warm the git content cache for other.yaml, as on a refresh: the crash
    -- needs the virtual side's load callback to run synchronously.
    local warmed = false
    require("codediff.core.git.content").get_file_content(sha, repo.dir, "other.yaml", function(err, lines)
      warmed = err == nil and lines ~= nil
    end)
    vim.wait(3000, function()
      return warmed
    end)
    assert.is_true(warmed, "git content cache should warm for other.yaml")

    -- Control case: an ordinary view renders normally.
    view.create(config_for("config.yaml"))
    tab = vim.api.nvim_get_current_tabpage()
    vim.wait(3000, diff_ready)
    assert.is_true(diff_ready(), "control view should render its diff")

    -- Stand-in for yaml-companion's LspAttach handler: request_sync pumps
    -- the event loop with vim.wait while :edit is running.
    vim.api.nvim_create_augroup("CodeDiff592Repro", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = "CodeDiff592Repro",
      pattern = "yaml",
      callback = function()
        vim.wait(50)
      end,
    })

    -- The real side's buffer was never loaded, so this update must :edit it
    -- while the virtual side's readiness render is already queued.
    view.update(tab, config_for("other.yaml"))
    vim.wait(3000, diff_ready)
    local session = lifecycle.get_session(tab)
    assert.is_not_nil(session, "session should survive the update")
    assert.is_not_nil(session.stored_diff_result, "update should render a diff instead of crashing on a nil bufnr")
    assert.equal(1, #session.stored_diff_result.changes, "update should render the other.yaml change")
  end)
end)
