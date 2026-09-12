local h = require("tests.helpers")
local lifecycle = require("codediff.ui.lifecycle")
local refresh = require("codediff.ui.refresh")
local path = require("codediff.core.path")

describe("history refresh transport lifecycle", function()
  local repo, tab, original_watcher, handlers, unsubscribed
  before_each(function()
    repo = h.create_temp_git_repo()
    vim.cmd("tabnew")
    tab = vim.api.nvim_get_current_tabpage()
    original_watcher = package.loaded["codediff.core.watcher"]
    unsubscribed = 0
    package.loaded["codediff.core.watcher"] = {
      subscribe = function(root, callbacks)
        assert.equals(repo.dir, root)
        handlers = callbacks
        return function()
          unsubscribed = unsubscribed + 1
        end
      end,
    }
  end)
  after_each(function()
    lifecycle.cleanup(tab)
    package.loaded["codediff.core.watcher"] = original_watcher
    pcall(vim.cmd, "tabclose!")
    repo.cleanup()
  end)

  it("shares the native transport and falls back once after repeated errors", function()
    local a, b = vim.api.nvim_create_buf(false, true), vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_get_current_win()
    lifecycle.create_session(tab, {
      panel = { name = "history" },
      git_root = repo.dir,
      original = path.empty(),
      modified = path.empty(),
    }, { original_bufnr = a, modified_bufnr = b, original_win = win, modified_win = win, lines_diff = {} })
    local history = { git_root = repo.dir, bufnr = a, winid = win, opts = {}, commits = {}, is_hidden = false }
    lifecycle.set_panel_view(tab, history)
    require("codediff.ui.history.refresh").setup_auto_refresh(history, tab)
    local controller = lifecycle.get_session(tab).refresh
    assert.is_function(handlers.on_ready)
    handlers.on_ready()
    assert.is_true(history._native_watcher_ready)
    assert.is_false(controller.polling)
    handlers.on_error("EPERM")
    local timer = controller.poll
    assert.is_true(controller.polling)
    assert.is_false(history._native_watcher_ready)
    handlers.on_error("EPERM")
    assert.equals(timer, controller.poll)
    refresh.dispose(tab)
    assert.is_true(timer:is_closing())
    assert.equals(1, unsubscribed)
  end)
end)
