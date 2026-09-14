-- Session data owns refresh. Views consume changes and submit user selections.
local M = {}
local policy = require("codediff.ui.refresh.policy")
local inputs = require("codediff.ui.refresh.inputs")
local panels = require("codediff.ui.refresh.panel")
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
    return
  end
  self.pending = policy.merge(self.pending, policy.normalize(event))
  if done then
    self.callbacks[#self.callbacks + 1] = done
  end
  self:schedule()
end

local function notify_panel(panel, changes)
  if panel.view and panel.view.on_data then
    panel.view.on_data(panel.data, changes)
  end
end

function Controller:publish_panel(data)
  local panel = self.session.panel
  local previous = panel.data
  local key = panel.name == "history" and "commits" or "status_result"
  local list_changed = not vim.deep_equal(previous[key], data[key])
  if vim.deep_equal(previous, data) then
    data = previous
  end
  panel.data = data
  if panel.name == "explorer" and list_changed then
    panels.set_selection(panel, panels.reselect(previous, data.status_result))
  end
  local selection_changed = not panels.same_selection(previous.current_selection, data.current_selection)
  if not vim.deep_equal(previous, data) then
    notify_panel(panel, { list = list_changed, selection = selection_changed })
  end
  if selection_changed then
    M.select(self.tabpage, data.current_selection, { no_jump = true })
  elseif data.current_selection then
    local comparison = panels.comparison(panel)
    if
      comparison
      and self.session.single_side == comparison.single_side
      and self.session.merge == comparison.conflict
      and vim.deep_equal(self.session.original, comparison.original)
      and vim.deep_equal(self.session.modified, comparison.modified)
    then
      self.session.source_revisions = comparison.source_revisions
    end
  end
end

-- Publish only actual data changes. Edited Result buffers are never reseeded.
function Controller:publish(data, redraw)
  local session = self.session
  local changed = not inputs.same(self.last, data)
  local result_changed = session.result_bufnr and not vim.deep_equal(self.last and self.last.result, inputs.lines(session.result_bufnr))
  if session.result_bufnr and changed then
    local seed = session.result_base_lines or {}
    if not vim.deep_equal(inputs.lines(session.result_bufnr), #seed > 0 and seed or { "" }) then
      if not self.blocked or not inputs.same(self.blocked, data) then
        vim.notify("Conflict inputs changed; Result has unsaved edits. Reopen the conflict view to reload its inputs.", vim.log.levels.WARN)
        self.blocked = data
      end
      if result_changed or redraw then
        require("codediff.ui.conflict.view.result").render(session)
      end
      if self.last then
        self.last.result = inputs.lines(session.result_bufnr)
      end
      return
    end
  end
  if changed or result_changed or redraw then
    self.applying = true
    local ok, err = xpcall(function()
      require("codediff.ui.view.render").update(session, data, { inputs = changed, result = result_changed, redraw = redraw })
    end, debug.traceback)
    self.applying = false
    if not ok then
      error(err)
    end
  end
  self.blocked = nil
  data.result = session.result_bufnr and inputs.lines(session.result_bufnr) or nil
  self.last = data
end

function Controller:run()
  if not self:visible() or self.loading or self.running or not next(self.pending) and #self.callbacks == 0 then
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
  local function inspect(err, panel_data)
    if not current() then
      finish(nil, true)
      return
    end
    if err then
      finish(err)
      return
    end
    if panel_data then
      local ok, failure = pcall(self.publish_panel, self, panel_data)
      if not ok then
        finish(failure)
        return
      end
      if not current() then
        finish(nil, true)
        return
      end
    end
    self.last = self.last or inputs.capture(self.session)
    local read_ok, read_error = pcall(inputs.read, self.session, event, self.last, function(read_error, data)
      if not current() then
        finish(nil, true)
      elseif read_error then
        finish(read_error)
      elseif not inputs.valid(data) then
        self.pending = policy.merge(self.pending, { buffer = true })
        finish(nil, true)
      else
        local ok, failure = pcall(self.publish, self, data, event.render)
        finish(not ok and failure or nil)
      end
    end)
    if not read_ok then
      finish(read_error)
    end
  end
  if panel and panel.on_data and policy.panel_needed(self.session.panel, event) then
    local ok, err = pcall(panels.read, self.session, inspect)
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
  if self.session.panel and self.session.panel.name == "explorer" and require("codediff.config").options.explorer.auto_refresh == false then
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
      if current() then
        self.native, self.polling = true, false
        self.poll:stop()
        self:request({ full = true })
      end
    end,
    on_refresh = function(message)
      if current() then
        self:request(message)
      end
    end,
    on_error = function()
      if current() then
        self.native = false
        self:start_polling()
        self:request({ full = true })
      end
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
      for _, input in pairs(inputs.describe(session)) do
        belongs = belongs or input.path and input.path.absolute ~= "" and input.path.absolute == name
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
    self.last = inputs.capture(session)
    self.blocked = nil
    if next(self.pending) or #self.callbacks > 0 then
      self:schedule()
    end
  end)
end

function M.select(tabpage, file, opts)
  local self = M.attach(tabpage)
  local session = self and self.session
  local panel = session and session.panel
  if not panel then
    return false
  end
  opts = opts or {}
  local changed = not panels.same_selection(panel.data.current_selection, file)
  panels.set_selection(panel, file)
  if changed then
    notify_panel(panel, { selection = true })
  end
  if not file then
    M.begin(tabpage, {})
    require("codediff.ui.view").show_welcome(tabpage)
    return true
  end
  local comparison = panels.comparison(panel, file)
  if not comparison then
    return false
  end
  if panel.name == "explorer" then
    vim.api.nvim_exec_autocmds("User", {
      pattern = "CodeDiffFileSelect",
      modeline = false,
      data = { tabpage = tabpage, path = file.path, status = file.status },
    })
  end
  local same = session.single_side == comparison.single_side
    and session.merge == comparison.conflict
    and vim.deep_equal(session.original, comparison.original)
    and vim.deep_equal(session.modified, comparison.modified)
    and vim.deep_equal(session.source_revisions, comparison.source_revisions)
  if same and not opts.force then
    return true
  end
  local generation = M.begin(tabpage, comparison)
  local view = panel.view
  panels.resolve(comparison, function(err, resolved)
    vim.schedule(function()
      if not M.is_current(tabpage, session, generation) or session.panel ~= panel or panel.view ~= view then
        return
      end
      if err then
        vim.notify(err, vim.log.levels.ERROR)
        M.ready(tabpage)
        return
      end
      local jump = not opts.no_jump and require("codediff.config").options.diff.jump_to_first_change
      require("codediff.ui.view").show(tabpage, resolved, jump)
    end)
  end)
  return true
end

function M.load_commit_files(tabpage, hash, done)
  local self = M.attach(tabpage)
  local panel = self and self.session.panel
  if not panel or panel.name ~= "history" then
    return
  end
  local view = panel.view
  panels.load_files(panel.data, hash, function(err, files)
    if not self:valid() or self.session.panel ~= panel or panel.view ~= view then
      return
    end
    if not err then
      panel.data.files[hash] = files
      notify_panel(panel, { files = hash })
    else
      vim.notify("Failed to load commit files: " .. err, vim.log.levels.ERROR)
    end
    if done then
      done(err)
    end
  end)
end

function M.reopen(tabpage)
  local session = session_for(tabpage)
  if session and session.panel then
    return M.select(tabpage, session.panel.data.current_selection, { force = true, no_jump = true })
  end
  return false
end

function M.replay(tabpage)
  local self = M.attach(tabpage)
  if self and not self.loading then
    self:publish(inputs.capture(self.session), true)
  end
end

function M.request(tabpage, event, done)
  local self = M.attach(tabpage)
  if self then
    self:request(event, done)
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

-- Resolution commands render their local edits synchronously, without reading Git.
function M.refresh_result_now(buf)
  for _, session in pairs(require("codediff.ui.lifecycle.session").get_active_diffs()) do
    if buf == session.result_bufnr then
      require("codediff.ui.conflict.view.result").render(session)
    end
  end
end

return M
