local M = {}
local Screen = require("tests.framework.screen")
local fixture = require("tests.fixtures.refresh_repo")
local watcher_path

function M.native_watcher()
  if require("codediff.core.installer.common").detect_os() == "android" then
    pending("No native watcher release for Android; polling E2Es run separately")
  end
  if not watcher_path then
    local saved = vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL
    vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL = nil
    local install_error
    require("codediff.core.installer.watcher").ensure(function(path, err)
      watcher_path, install_error = path, err
    end)
    vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL = saved
    assert(watcher_path and vim.fn.filereadable(watcher_path) == 1, "Native E2Es require codediff-watcher: " .. tostring(install_error))
  end
  return watcher_path
end

function M.repo(profile, options)
  return fixture.new(profile, options)
end

function M.screen(backend, layout, options)
  local binary = backend == "native" and M.native_watcher() or ""
  local screen = Screen.new(120, 40)
  screen.backend = backend
  screen:exec(
    [[
    local backend, layout, binary, options = ...
    vim.g.mapleader = ' '
    require('codediff').setup(vim.tbl_deep_extend('force', {
      diff = { layout = layout, jump_to_first_change = false, compute_moves = false },
      explorer = { width = 28 },
    }, options))
    vim.o.hidden = true
    vim.o.autoread = true
    vim.o.number = false
    vim.o.relativenumber = false
    vim.o.foldcolumn = '0'
    vim.o.scrolloff = 0
    _G.refresh_test = { received = 0, reads = 0, pending = 0, scheduled = 0, errors = {}, notifications = {} }
    local test = refresh_test
    if backend == 'native' then
      vim.env.CODEDIFF_WATCHER_PATH = binary
      local uv = vim.uv or vim.loop
      local spawn = uv.spawn
      uv.spawn = function(command, options, done)
        local handle, pid = spawn(command, options, done)
        if command == binary then test.watcher_pid = pid end
        return handle, pid
      end
    else
      require('codediff.core.installer.watcher').ensure = function(done)
        done(nil, 'native transport disabled for polling E2E')
      end
    end
    -- Observe the real transport and Git requests, without replacing their work.
    local watcher = require('codediff.core.watcher')
    local subscribe = watcher.subscribe
    watcher.subscribe = function(root, handlers)
      local ready, refresh, failed = handlers.on_ready, handlers.on_refresh, handlers.on_error
      handlers.on_ready = function(message)
        test.native_ready = true
        if ready then ready(message) end
      end
      handlers.on_refresh = function(message)
        test.received = test.received + 1
        test.last_message = message
        if refresh then refresh(message) end
      end
      handlers.on_error = function(message)
        test.fallback = true
        if failed then failed(message) end
      end
      return subscribe(root, handlers)
    end
    local runner = require('codediff.core.git.runner')
    local run = runner.run_async
    runner.run_async = function(args, options, done)
      test.pending = test.pending + 1
      test.reads = test.reads + 1
      return run(args, options, function(...)
        test.pending = test.pending - 1
        done(...)
      end)
    end
    local git = require('codediff.core.git')
    for _, name in ipairs({ 'get_status_with_line_stats', 'get_diff_staged', 'get_diff_revision_with_line_stats', 'get_diff_revisions_with_line_stats', 'get_file_content', 'get_commit_list' }) do
      local original = git[name]
      git[name] = function(...)
        local args, count = { ... }, select('#', ...)
        for i = 1, count do
          if type(args[i]) == 'function' then
            local callback = args[i]
            test.reads = test.reads + 1
            test.pending = test.pending + 1
            args[i] = function(...)
              test.pending = test.pending - 1
              return callback(...)
            end
            break
          end
        end
        return original(unpack(args, 1, count))
      end
    end
    local schedule = vim.schedule
    vim.schedule = function(fn)
      test.scheduled = test.scheduled + 1
      schedule(function()
        local ok, err = xpcall(fn, debug.traceback)
        test.scheduled = test.scheduled - 1
        if not ok then test.errors[#test.errors + 1] = tostring(err) end
      end)
    end
    vim.notify = function(message, level)
      local record = { message = tostring(message), level = level }
      test.notifications[#test.notifications + 1] = record
      if level == vim.log.levels.ERROR then test.errors[#test.errors + 1] = tostring(message) end
    end
    _G.refresh_session = function()
      return require('codediff.ui.lifecycle').get_session(refresh_test.tab or vim.api.nvim_get_current_tabpage())
    end
  ]],
    { backend, layout or "side-by-side", binary, options or {} }
  )
  return screen
end

function M.open(screen, repo, command, expected, source_file)
  screen:exec(
    [[
    local root, command, source_file = ...
    refresh_test.tab = nil
    vim.cmd('cd ' .. vim.fn.fnameescape(root))
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. source_file))
    vim.cmd(command)
  ]],
    { repo.dir, command or "CodeDiff", source_file or "a.txt" }
  )
  screen:await(function()
    M.assert_no_errors(screen)
    return screen:exec(
      [[
      local expected = ...
      local s = refresh_session()
      if not s or not s.stored_diff_result then return false end
      if expected and not ((s.modified and s.modified.absolute:sub(-#expected) == expected)
        or (s.original and s.original.absolute:sub(-#expected) == expected)) then return false end
      refresh_test.tab = vim.api.nvim_get_current_tabpage()
      return true
    ]],
      { expected or "a.txt" }
    )
  end, "CodeDiff did not open the requested file")
  if screen.backend == "native" then
    screen:await(function()
      return screen:exec("return refresh_test.native_ready == true")
    end, "Native watcher never became ready; fallback is not a native E2E pass")
  end
  M.idle(screen)
end

function M.idle(screen)
  screen:await(function()
    M.assert_no_errors(screen)
    return screen:exec([[
      local s = refresh_session()
      local controller = s and s.refresh
      return refresh_test.pending == 0 and refresh_test.scheduled == 0
        and (not s or s.stored_diff_result ~= nil)
        and (not controller or controller.closed or not controller.running and not controller.loading
          and not next(controller.pending) and not controller.timer:is_active())
    ]])
  end, "refresh did not settle")
end

function M.assert_no_errors(screen)
  local errors = screen:exec("return refresh_test.errors")
  assert.same({}, errors, "unhandled error in embedded Neovim")
end

function M.checkpoint(screen)
  return screen:exec("return { received = refresh_test.received, reads = refresh_test.reads }")
end

function M.wait_event(screen, before)
  screen:await(function()
    M.assert_no_errors(screen)
    return screen:exec(
      [[
      local before, native = ...
      return native and refresh_test.received > before.received or not native and refresh_test.reads > before.reads
    ]],
      { before, screen.backend == "native" }
    )
  end, "the external change was not observed")
  M.idle(screen)
end

function M.panes(screen)
  return screen:exec([[
    local s = refresh_session()
    local result = { tab = refresh_test.tab, focused = vim.api.nvim_get_current_win(), layout = s.layout }
    for _, side in ipairs({ 'original', 'modified', 'result' }) do
      local buf, win = s[side .. '_bufnr'], s[side .. '_win']
      if buf and vim.api.nvim_buf_is_valid(buf) then
        local pane = { buf = buf, lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false), win = win }
        if win and vim.api.nvim_win_is_valid(win) then
          local v = vim.api.nvim_win_call(win, vim.fn.winsaveview)
          pane.view = { v.topline, v.topfill, v.leftcol, v.lnum, v.col }
          pane.width = vim.api.nvim_win_get_width(win)
          pane.height = vim.api.nvim_win_get_height(win)
        end
        result[side] = pane
      end
    end
    return result
  ]])
end

function M.contains(screen, side, text)
  local rect = screen:exec(
    [[
    local s = refresh_session()
    local win = s and s[(...) .. '_win']
    if not win or not vim.api.nvim_win_is_valid(win) then return nil end
    local p = vim.api.nvim_win_get_position(win)
    return { p[1] + 1, p[2] + 1, vim.api.nvim_win_get_height(win), vim.api.nvim_win_get_width(win) }
  ]],
    { side }
  )
  if not rect then
    return false
  end
  for row = rect[1], math.min(screen.height, rect[1] + rect[3] - 1) do
    if screen:text(row, rect[2], rect[4]):find(text, 1, true) then
      return true
    end
  end
  return false
end

function M.expect_text(screen, side, text)
  screen:await(function()
    M.assert_no_errors(screen)
    return M.contains(screen, side, text)
  end, side .. " grid never showed " .. text)
end

-- Check stability throughout an observation window, not just at its last frame.
function M.preserved(screen, expected, duration)
  local finish = (vim.uv or vim.loop).hrtime() + (duration or 800) * 1e6
  repeat
    M.assert_no_errors(screen)
    assert.same(expected, M.panes(screen), "unrelated refresh changed the active view")
    vim.wait(20)
  until (vim.uv or vim.loop).hrtime() >= finish
  M.idle(screen)
  assert.same(expected, M.panes(screen))
end

-- Freeze the visible pane rectangles and compare every naturally flushed frame.
-- Only the panel may change during a repository-list-only update.
function M.watch_grid(screen)
  local rectangles = screen:exec([[
    local s, rectangles, seen = refresh_session(), {}, {}
    for _, side in ipairs({ 'original', 'modified', 'result' }) do
      local win = s[side .. '_win']
      if win and vim.api.nvim_win_is_valid(win) and not seen[win] then
        seen[win] = true
        local pos = vim.api.nvim_win_get_position(win)
        rectangles[#rectangles + 1] = { pos[1] + 1, pos[2] + 1, vim.api.nvim_win_get_height(win), vim.api.nvim_win_get_width(win) }
      end
    end
    return rectangles
  ]])
  local function cells()
    local result = {}
    for _, rect in ipairs(rectangles) do
      for row = rect[1], rect[1] + rect[3] - 1 do
        for col = rect[2], rect[2] + rect[4] - 1 do
          result[#result + 1] = { screen.grid[row][col][1], screen:highlight(row, col) }
        end
      end
    end
    return result
  end
  local expected, changed = vim.deepcopy(cells()), false
  screen.on_flush = function()
    changed = changed or not vim.deep_equal(expected, cells())
  end
  return function()
    screen.on_flush = nil
    assert.is_false(changed, "a repository-only refresh changed rendered diff cells")
    assert.same(expected, cells())
  end
end

function M.panel_cursor(screen, text, group)
  screen:exec(
    [[
    local text, group = ...
    local panel = refresh_session().panel.view
    vim.api.nvim_set_current_win(panel.winid)
    for row, line in ipairs(vim.api.nvim_buf_get_lines(panel.bufnr, 0, -1, false)) do
      local node = panel.tree:get_node(row)
      if line:find(text, 1, true) and (not group or node and node.data and node.data.group == group) then
        vim.api.nvim_win_set_cursor(panel.winid, { row, 0 })
        return
      end
    end
    error('entry is absent from the rendered panel: ' .. text)
  ]],
    { text, group }
  )
end

function M.select(screen, filename, group)
  M.panel_cursor(screen, filename, group)
  M.feed(screen, "<CR>")
end

-- Delay delivery, not the actual Git read, to put user actions between request
-- and response. Repository notifications still come from the real transport.
function M.hold_content(screen, path)
  screen:exec(
    [[
    local path = ...
    local git = require('codediff.core.git')
    local get = git.get_file_content
    refresh_test.held = {}
    refresh_test.hold = true
    git.get_file_content = function(revision, root, filename, done)
      return get(revision, root, filename, function(err, value)
        if refresh_test.hold and filename == path then
          refresh_test.held[#refresh_test.held + 1] = function() done(err, value) end
        else done(err, value) end
      end)
    end
  ]],
    { path }
  )
end

function M.release_content(screen)
  screen:exec([[
    refresh_test.hold = false
    local held = refresh_test.held
    refresh_test.held = {}
    for _, done in ipairs(held) do done() end
  ]])
end

function M.feed(screen, keys)
  screen:exec("refresh_test.keys_done = false")
  screen:input(keys .. "<Cmd>lua refresh_test.keys_done = true<CR>")
  screen:await(function()
    return screen:exec("return refresh_test.keys_done")
  end, "keys did not finish")
end

function M.focus(screen, side, line)
  screen:exec(
    [[
    local side, line = ...
    local s = refresh_session()
    local win = side == 'panel' and s.panel.view.winid or s[side .. '_win']
    assert(win and vim.api.nvim_win_is_valid(win), 'pane is not visible: ' .. side)
    vim.api.nvim_set_current_win(win)
    if line then vim.api.nvim_win_set_cursor(win, { line, 0 }) end
  ]],
    { side, line }
  )
end

function M.key(screen, group, action)
  return screen:exec(
    [[
    local group, action = ...
    local key = require('codediff.config').options.keymaps[group][action]
    assert(type(key) == 'string', 'missing key binding: ' .. group .. '.' .. action)
    return key:gsub('<[Ll]eader>', vim.g.mapleader or '\\'):gsub('<[Ll]ocal[Ll]eader>', vim.g.maplocalleader or '\\')
  ]],
    { group, action }
  )
end

function M.action(screen, group, action, side, line)
  if side then
    M.focus(screen, side, line)
  end
  M.feed(screen, M.key(screen, group, action))
end

function M.grid_contains(screen, text)
  for row = 1, screen.height do
    if screen:text(row, 1, screen.width):find(text, 1, true) then
      return true
    end
  end
  return false
end

function M.panel_contains(screen, text)
  local rect = screen:exec([[
    local panel = refresh_session().panel.view
    if panel.is_hidden or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then return nil end
    local p = vim.api.nvim_win_get_position(panel.winid)
    return { p[1] + 1, p[2] + 1, vim.api.nvim_win_get_height(panel.winid), vim.api.nvim_win_get_width(panel.winid) }
  ]])
  if not rect then
    return false
  end
  for row = rect[1], rect[1] + rect[3] - 1 do
    if screen:text(row, rect[2], rect[4]):find(text, 1, true) then
      return true
    end
  end
  return false
end

function M.expect_panel(screen, text, present)
  screen:await(function()
    M.assert_no_errors(screen)
    return M.panel_contains(screen, text) == (present ~= false)
  end, "panel grid did not " .. (present == false and "remove " or "show ") .. text)
end

function M.reveal(screen, side, text)
  M.focus(screen, side)
  screen:exec(
    [[
    local text = ...
    for line, value in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if value:find(text, 1, true) then
        vim.api.nvim_win_set_cursor(0, { line, 0 })
        return
      end
    end
    error('buffer does not contain ' .. text)
  ]],
    { text }
  )
  M.feed(screen, "zz")
  M.expect_text(screen, side, text)
end

-- Confirm through Neovim's actual dialog, without replacing vim.fn.confirm.
function M.confirm(screen, keys, prompt, answer)
  screen:input(keys)
  screen:await(function()
    return M.grid_contains(screen, prompt)
  end, "confirmation prompt was not rendered")
  screen:input(answer)
  M.feed(screen, "")
end

function M.expect_lines(screen, side, expected)
  screen:await(function()
    M.assert_no_errors(screen)
    local panes = M.panes(screen)
    return panes[side] and vim.deep_equal(expected, panes[side].lines)
  end, side .. " contents did not match the fixture expectation")
end

function M.cell_for(screen, side, text)
  local rect = screen:exec(
    [[
    local s = refresh_session()
    local win = s[(...) .. '_win']
    if not win or not vim.api.nvim_win_is_valid(win) then return nil end
    local p = vim.api.nvim_win_get_position(win)
    return { p[1] + 1, p[2] + 1, vim.api.nvim_win_get_height(win), vim.api.nvim_win_get_width(win) }
  ]],
    { side }
  )
  if not rect then
    return
  end
  for row = rect[1], rect[1] + rect[3] - 1 do
    local value = screen:text(row, rect[2], rect[4])
    local first = value:find(text, 1, true)
    if first then
      return row, rect[2] + vim.fn.strdisplaywidth(value:sub(1, first - 1))
    end
  end
end

function M.window_text(screen, win)
  local rect = screen:exec(
    [[
    local win = ...
    if not vim.api.nvim_win_is_valid(win) then return nil end
    local p = vim.api.nvim_win_get_position(win)
    local border = vim.api.nvim_win_get_config(win).border
    local top = border and border[2] and border[2] ~= '' and 1 or 0
    local left = border and border[8] and border[8] ~= '' and 1 or 0
    return { p[1] + 1 + top, p[2] + 1 + left, vim.api.nvim_win_get_height(win), vim.api.nvim_win_get_width(win) }
  ]],
    { win }
  )
  if not rect then
    return ""
  end
  local rows = {}
  for row = rect[1], rect[1] + rect[3] - 1 do
    rows[#rows + 1] = screen:text(row, rect[2], rect[4])
  end
  return table.concat(rows):gsub("%s+$", "")
end

function M.close(screen, repo)
  local ok, err = true, nil
  if screen then
    if screen.exit_code == nil then
      ok, err = pcall(M.assert_no_errors, screen)
    end
    screen:close()
  end
  if repo then
    repo.cleanup()
  end
  assert(ok, err)
end

return M
