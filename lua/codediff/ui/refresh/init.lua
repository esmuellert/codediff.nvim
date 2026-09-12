-- One refresh controller per session: collect invalidations, inspect data, apply changes.
local M = {}
local policy = require("codediff.ui.refresh.policy")
local snapshot = require("codediff.ui.refresh.snapshot")
local apply = require("codediff.ui.refresh.apply")
local uv = vim.uv or vim.loop
local Controller = {}
Controller.__index = Controller

local function session_for(tabpage)
  return require("codediff.ui.lifecycle").get_session(tabpage)
end

function Controller:valid()
  return not self.closed and session_for(self.tabpage) == self.session and vim.api.nvim_tabpage_is_valid(self.tabpage)
end

function Controller:visible()
  if not self:valid() or vim.api.nvim_get_current_tabpage() ~= self.tabpage or self.session.suspended then
    return false
  end
  local root = self.session.git_root
  return not root or root == "" or (vim.fn.isdirectory(root) == 1 and (vim.fn.isdirectory(root .. "/.git") == 1 or vim.fn.filereadable(root .. "/.git") == 1))
end

function Controller:schedule(delay)
  if self.closed or self.running or self.loading or not self:visible() then
    return
  end
  self.timer:stop()
  self.timer:start(
    delay or 20,
    0,
    vim.schedule_wrap(function()
      self:run()
    end)
  )
end

function Controller:request(event, done)
  if self.closed then
    if done then
      done()
    end
    return
  end
  self.pending = policy.merge(self.pending, policy.normalize(event))
  if done then
    self.callbacks[#self.callbacks + 1] = done
  end
  self:schedule()
end

function Controller:run()
  if not self:visible() or self.loading or self.running then
    return
  end
  if not next(self.pending) and #self.callbacks == 0 then
    return
  end
  local event, callbacks, generation = self.pending, self.callbacks, self.generation
  local panel = require("codediff.ui.lifecycle").get_panel_view(self.tabpage)
  local function owns_panel()
    return require("codediff.ui.lifecycle").get_panel_view(self.tabpage) == panel
  end
  self.pending, self.callbacks, self.running = {}, {}, true
  local finished = false
  local function finish(err, cancelled)
    if finished then
      return
    end
    finished, self.running = true, false
    if not self:valid() then
      return
    end
    if err or cancelled then
      self.pending = policy.merge(event, self.pending)
      -- A completion may navigate or restore a cursor: never replay it onto
      -- a different file or a replacement panel.
      if self.generation == generation and owns_panel() then
        vim.list_extend(self.callbacks, callbacks)
      end
      if err then
        vim.notify_once("CodeDiff refresh: " .. tostring(err), vim.log.levels.WARN)
      end
    else
      for _, callback in ipairs(callbacks) do
        callback()
      end
    end
    if next(self.pending) or #self.callbacks > 0 then
      self:schedule(err and 500 or 20)
    end
  end
  local function current()
    return not finished and self:visible() and not self.loading and self.generation == generation and owns_panel()
  end
  local function inspect(panel_error)
    if not current() then
      finish(nil, true)
      return
    end
    if panel_error then
      finish(panel_error)
      return
    end
    if not self.last then
      self.last = snapshot.capture(self.session)
    end
    local read_ok, read_error = pcall(snapshot.read, self.session, event, self.last, function(err, data)
      if not current() then
        finish(nil, true)
        return
      end
      if err then
        finish(err)
        return
      end
      if not snapshot.valid(data) then
        self.pending = policy.merge(self.pending, { buffer = true })
        finish(nil, true)
        return
      end
      self.applying = true
      local ok, accepted = xpcall(function()
        return apply.run(self.session, data, self.last, event.render)
      end, debug.traceback)
      self.applying = false
      if not ok then
        finish(accepted)
        return
      end
      if accepted then
        self.blocked = nil
        data.result = self.session.result_bufnr and snapshot.lines(self.session.result_bufnr) or nil
        self.last = data
      elseif self.last then
        self.last.result = snapshot.lines(self.session.result_bufnr)
      end
      finish()
    end)
    if not read_ok then
      finish(read_error)
    end
  end
  if self.panel_refresh and policy.panel_needed(self.session.panel, event) then
    local ok, err = pcall(self.panel_refresh, inspect)
    if not ok then
      finish(err)
    end
  else
    inspect()
  end
end

function Controller:start_polling()
  if self.polling or self.closed then
    return
  end
  self.polling = true
  self.poll:start(
    500,
    500,
    vim.schedule_wrap(function()
      self:request({ full = true })
    end)
  )
end

-- A file-follow operation may move the session to another repository.
function Controller:watch()
  self.watch_generation = (self.watch_generation or 0) + 1
  local generation = self.watch_generation
  if self.unsubscribe then
    self.unsubscribe()
    self.unsubscribe = nil
  end
  self.git_root = self.session.git_root
  self.native, self.polling = false, false
  self.poll:stop()
  local panel = self.session.panel and self.session.panel.view
  if panel then
    panel._native_watcher_ready = false
  end
  local automatic = not (self.session.panel and self.session.panel.name == "explorer" and require("codediff.config").options.explorer.auto_refresh == false)
  if not automatic then
    return
  end
  self:start_polling()
  if not self.git_root or self.git_root == "" then
    return
  end
  local function current()
    return self:valid() and self.watch_generation == generation
  end
  self.unsubscribe = require("codediff.core.watcher").subscribe(self.git_root, {
    on_ready = function()
      if not current() then
        return
      end
      self.native, self.polling = true, false
      self.poll:stop()
      local view = self.session.panel and self.session.panel.view
      if view then
        view._native_watcher_ready = true
      end
      self:request({ full = true })
    end,
    on_refresh = function(message)
      if current() then
        self:request(message)
      end
    end,
    on_error = function()
      if not current() then
        return
      end
      self.native = false
      local view = self.session.panel and self.session.panel.view
      if view then
        view._native_watcher_ready = false
      end
      self:start_polling()
      self:request({ full = true })
    end,
  })
end

function Controller:dispose()
  if self.closed then
    return
  end
  self.closed = true
  for _, timer in ipairs({ self.timer, self.poll }) do
    timer:stop()
    timer:close()
  end
  if self.unsubscribe then
    self.unsubscribe()
  end
  pcall(vim.api.nvim_del_augroup_by_id, self.group)
  self.callbacks, self.pending = {}, {}
end

function M.attach(tabpage)
  local session = session_for(tabpage)
  if not session then
    return
  end
  if session.refresh and not session.refresh.closed then
    return session.refresh
  end
  local self = setmetatable({
    tabpage = tabpage,
    session = session,
    generation = 0,
    pending = {},
    callbacks = {},
    timer = assert(uv.new_timer()),
    poll = assert(uv.new_timer()),
  }, Controller)
  session.refresh = self
  self.group = vim.api.nvim_create_augroup("CodeDiffRefresh_" .. tabpage, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "FileChangedShellPost" }, {
    group = self.group,
    callback = function(event)
      if not self:valid() or self.applying then
        return
      end
      local name = vim.api.nvim_buf_get_name(event.buf)
      local belongs = event.buf == session.original_bufnr or event.buf == session.modified_bufnr or event.buf == session.result_bufnr
      if not belongs then
        for _, input in pairs(snapshot.describe(session)) do
          if input.path and input.path.absolute ~= "" and input.path.absolute == name then
            belongs = true
          end
        end
      end
      if belongs then
        self:request({ buffer = true })
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = self.group,
    callback = function(event)
      if event.buf ~= session.original_bufnr and event.buf ~= session.modified_bufnr then
        return
      end
      vim.schedule(function()
        if not self:valid() or self.loading or self.applying then
          return
        end
        if not vim.api.nvim_buf_is_valid(session.original_bufnr) or not vim.api.nvim_buf_is_valid(session.modified_bufnr) then
          require("codediff.ui.lifecycle").cleanup(tabpage)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "TabEnter", "FocusGained" }, {
    group = self.group,
    callback = function()
      if vim.api.nvim_get_current_tabpage() == tabpage then
        self:request({ full = true })
      end
    end,
  })
  self:watch()
  M.ready(tabpage)
  return self
end

-- Opening/retargeting owns the view until its complete input set is installed.
function M.begin(tabpage, request)
  local self = M.attach(tabpage)
  if not self then
    return
  end
  self.generation = self.generation + 1
  self.loading = true
  if request then
    self.session.source_revisions = request.source_revisions
  end
  return self.generation
end

function M.is_current(tabpage, session, generation)
  return session_for(tabpage) == session and vim.api.nvim_tabpage_is_valid(tabpage) and (not generation or session.refresh and session.refresh.generation == generation)
end

function M.ready(tabpage)
  local session = session_for(tabpage)
  local self = session and session.refresh
  if not self or self.closed then
    return
  end
  local generation = self.generation
  vim.schedule(function()
    if not self:valid() or generation ~= self.generation then
      return
    end
    self.loading = false
    if self.git_root ~= session.git_root then
      self:watch()
    end
    self.last = snapshot.capture(session)
    self.blocked = nil
    if next(self.pending) or #self.callbacks > 0 then
      self:schedule()
    end
  end)
end

function M.replay(tabpage)
  local self = M.attach(tabpage)
  if not self or self.loading then
    return
  end
  local data = snapshot.capture(self.session)
  self.applying = true
  local ok, err = xpcall(function()
    apply.run(self.session, data, self.last, true)
  end, debug.traceback)
  self.applying = false
  if not ok then
    error(err)
  end
end

function M.request(tabpage, event, done)
  local self = M.attach(tabpage)
  if self then
    self:request(event, done)
  elseif done then
    done()
  end
end

function M.bind_panel(tabpage, panel, refresh)
  local self = M.attach(tabpage)
  if not self then
    return function() end
  end
  self.panel_refresh = refresh
  panel._native_watcher_ready = self.native == true
  return function()
    if self.panel_refresh == refresh then
      self.panel_refresh = nil
    end
  end
end

function M.dispose(tabpage)
  local session = session_for(tabpage)
  if session and session.refresh then
    session.refresh:dispose()
    session.refresh = nil
  end
end

function M.buffer_changed(buf)
  for tabpage, session in pairs(require("codediff.ui.lifecycle.session").get_active_diffs()) do
    if buf == session.original_bufnr or buf == session.modified_bufnr or buf == session.result_bufnr then
      M.request(tabpage, { buffer = true })
    end
  end
end

return M
