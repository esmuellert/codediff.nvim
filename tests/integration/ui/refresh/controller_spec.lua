local refresh = require("codediff.ui.refresh")
local snapshot = require("codediff.ui.refresh.inputs")
local render = require("codediff.ui.view.render")
local lifecycle = require("codediff.ui.lifecycle")
local path = require("codediff.core.path")

describe("session refresh scheduling", function()
  local old_timer, old_watcher, old_read, old_apply, old_auto
  local timers, handlers, reads, applied, unsubscribed, controller, session, tab, root
  local uv = vim.uv or vim.loop

  before_each(function()
    vim.cmd("tabnew")
    tab = vim.api.nvim_get_current_tabpage()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/.git", "p")
    timers, reads, applied = {}, {}, 0
    handlers = nil
    unsubscribed = false
    old_timer = uv.new_timer
    uv.new_timer = function()
      local timer = {}
      function timer:start(_, repeat_ms, callback)
        self.started = true
        self.repeat_ms = repeat_ms
        self.callback = callback
      end
      function timer:stop()
        self.started = false
      end
      function timer:close()
        self.closed = true
      end
      function timer:is_closing()
        return self.closed == true
      end
      timers[#timers + 1] = timer
      return timer
    end
    old_watcher = package.loaded["codediff.core.watcher"]
    package.loaded["codediff.core.watcher"] = {
      subscribe = function(_, callbacks)
        handlers = callbacks
        return function()
          unsubscribed = true
        end
      end,
    }
    old_read, old_apply = snapshot.read, render.update
    snapshot.read = function(_, event, _, done)
      reads[#reads + 1] = { event = event, done = done }
    end
    render.update = function()
      applied = applied + 1
      return true
    end
    old_auto = require("codediff.config").options.explorer.auto_refresh
    require("codediff.config").options.explorer.auto_refresh = true
  end)

  after_each(function()
    refresh.dispose(tab)
    snapshot.read, render.update = old_read, old_apply
    package.loaded["codediff.core.watcher"] = old_watcher
    uv.new_timer = old_timer
    require("codediff.config").options.explorer.auto_refresh = old_auto
    lifecycle.cleanup(tab)
    pcall(vim.cmd, "tabclose!")
    vim.fn.delete(root, "rf")
  end)

  local function setup()
    local a = vim.api.nvim_create_buf(false, true)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(a, 0, -1, false, { "a" })
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "b" })
    local win = vim.api.nvim_get_current_win()
    lifecycle.create_session(tab, {
      git_root = root,
      original = path.make_ref("a.txt", root),
      modified = path.make_ref("a.txt", root),
      original_revision = ":0",
      modified_revision = "WORKING",
      panel = { name = "explorer" },
    }, { original_bufnr = a, modified_bufnr = b, original_win = win, modified_win = win, lines_diff = { changes = {} } })
    session = lifecycle.get_session(tab)
    controller = refresh.attach(tab)
    uv.new_timer = old_timer
    vim.wait(10)
  end

  local function fire()
    timers[1].callback()
    vim.wait(10)
  end

  it("stops fallback after ready and preserves every queued event category", function()
    setup()
    assert.is_true(controller == refresh.attach(tab))
    assert.equals(2, #timers)
    assert.is_true(timers[2].started)
    handlers.on_ready()
    assert.is_false(timers[2].started)
    fire()
    assert.equals(1, #reads)
    assert.is_true(reads[1].event.full)
    handlers.on_refresh({ worktree = true })
    handlers.on_refresh({ index = true, refs = true })
    assert.equals(1, #reads)
    reads[1].done(nil, snapshot.capture(session))
    fire()
    assert.same({ worktree = true, index = true, refs = true }, reads[2].event)
  end)

  it("completes unchanged-data callbacks without notifying the diff renderer", function()
    setup()
    local completed = 0
    controller:request({ index = true }, function()
      completed = completed + 1
    end)
    fire()
    assert.equals(0, completed)
    reads[1].done(nil, snapshot.capture(session))
    assert.equals(0, applied)
    assert.equals(1, completed)
  end)

  it("uses full data checks rather than forced reinitialization for fallback", function()
    setup()
    handlers.on_error("watcher exited")
    assert.is_true(timers[2].started)
    timers[2].callback()
    vim.wait(10)
    fire()
    assert.same({ full = true }, reads[1].event)
  end)

  it("does not queue redundant polling work while a slow read is running", function()
    setup()
    timers[2].callback()
    vim.wait(10)
    fire()
    assert.is_true(controller.running)
    assert.equals(500, timers[2].repeat_ms)
    for _ = 1, 3 do
      timers[2].callback()
      vim.wait(10)
    end
    assert.same({}, controller.pending)
    reads[1].done(nil, snapshot.capture(session))
    assert.is_false(controller.running)
    assert.same({}, controller.pending)
    timers[2].callback()
    vim.wait(10)
    fire()
    assert.equals(2, #reads, "the next idle polling tick must still check data")
  end)

  it("preserves real invalidations while redundant polling ticks are coalesced", function()
    setup()
    controller:request({ full = true })
    fire()
    handlers.on_refresh({ index = true, worktree = true })
    timers[2].callback()
    vim.wait(10)
    assert.same({ index = true, worktree = true }, controller.pending)
    reads[1].done(nil, snapshot.capture(session))
    fire()
    assert.same({ index = true, worktree = true }, reads[2].event)
  end)

  it("does not poll through an unfinished selection or a stopped transport", function()
    setup()
    refresh.begin(tab)
    timers[2].callback()
    vim.wait(10)
    assert.same({}, controller.pending)
    refresh.ready(tab)
    vim.wait(10)
    handlers.on_ready()
    fire()
    reads[1].done(nil, snapshot.capture(session))
    timers[2].callback()
    vim.wait(10)
    assert.same({}, controller.pending, "an already queued fallback tick must not outlive native readiness")
  end)

  it("discards an in-flight snapshot after retargeting", function()
    setup()
    controller:request({ index = true })
    fire()
    refresh.begin(tab)
    reads[1].done(nil, snapshot.capture(session))
    assert.equals(0, applied)
    assert.is_true(controller.pending.index)
  end)

  it("does not replay completion callbacks onto a newer selection", function()
    setup()
    local completed = 0
    controller:request({ index = true }, function()
      completed = completed + 1
    end)
    fire()
    refresh.begin(tab)
    reads[1].done(nil, snapshot.capture(session))
    refresh.ready(tab)
    vim.wait(10)
    fire()
    reads[2].done(nil, snapshot.capture(session))
    assert.equals(0, completed)
  end)

  it("tears down timers and the subscription even with a read in flight", function()
    setup()
    controller:request({ full = true })
    fire()
    refresh.dispose(tab)
    reads[1].done(nil, snapshot.capture(session))
    assert.equals(0, applied)
    assert.is_true(unsubscribed)
    for _, timer in ipairs(timers) do
      assert.is_true(timer.closed)
    end
  end)

  it("defers hidden-tab work, but does not drop its invalidations", function()
    setup()
    session.suspended = true
    handlers.on_refresh({ index = true })
    assert.equals(0, #reads)
    assert.is_true(controller.pending.index)
    session.suspended = false
    controller:request({ render = true })
    fire()
    assert.is_true(reads[1].event.index)
    assert.is_true(reads[1].event.render)
  end)

  it("retries a synchronous source error instead of leaving the queue running forever", function()
    setup()
    local reader = snapshot.read
    snapshot.read = function()
      error("temporary source failure")
    end
    controller:request({ index = true })
    local ok = pcall(controller.run, controller)
    assert.is_true(ok)
    assert.is_false(controller.running)
    snapshot.read = reader
    fire()
    local data = snapshot.capture(session)
    data.original = { "new content" }
    reads[1].done(nil, data)
    assert.equals(1, applied)
  end)

  it("rejects snapshots whose working buffers changed during the read", function()
    setup()
    controller:request({ index = true })
    fire()
    local data = snapshot.capture(session)
    data.ticks = { [session.modified_bufnr] = vim.api.nvim_buf_get_changedtick(session.modified_bufnr) }
    vim.api.nvim_buf_set_lines(session.modified_bufnr, 0, -1, false, { "edited while reading" })
    reads[1].done(nil, data)
    assert.equals(0, applied)
    fire()
    assert.is_true(reads[2].event.buffer)
    reads[2].done(nil, snapshot.capture(session))
    assert.equals(1, applied)
  end)

  it("keeps working dependencies explicit without marking working panes as revisions", function()
    setup()
    local comparison = require("codediff.ui.refresh.panel").comparison(session.panel, { path = "a.txt", status = "M", group = "unstaged" })
    assert.is_nil(comparison.modified_revision)
    assert.equals("WORKING", comparison.source_revisions.modified)
    assert.equals(":0", comparison.source_revisions.original)
  end)

  it("publishes list data without invoking selection or diff rendering", function()
    setup()
    local observed
    local view = {
      on_data = function(data, changes)
        observed = { data = data, changes = changes }
      end,
      on_file_select = function()
        error("a data notification must not select a file through the view")
      end,
    }
    lifecycle.set_panel_view(tab, view)
    local next_data = vim.deepcopy(session.panel.data)
    next_data.status_result.unstaged = { { path = "background.txt", status = "M" } }
    controller:publish_panel(next_data)
    assert.is_true(session.panel.data == observed.data)
    assert.is_true(observed.changes.list)
    assert.is_false(observed.changes.selection)
    controller:publish(snapshot.capture(session))
    assert.equals(0, applied)
  end)

  it("notifies the diff renderer only when its inputs change", function()
    setup()
    local data = snapshot.capture(session)
    data.modified = { "new content" }
    controller:publish(data)
    assert.equals(1, applied)
    controller:publish(vim.deepcopy(data))
    assert.equals(1, applied)
  end)

  it("still accepts manual requests when automatic refresh is disabled", function()
    require("codediff.config").options.explorer.auto_refresh = false
    setup()
    assert.is_nil(handlers)
    local completed = 0
    controller:request({ full = true }, function()
      completed = completed + 1
    end)
    fire()
    reads[1].done(nil, snapshot.capture(session))
    assert.equals(1, completed)
  end)
end)
