local Screen = require("tests.framework.screen")

describe("conflict gutter preserves window options", function()
  local screen, win

  before_each(function()
    screen = Screen.new(80, 24)
    win = screen:exec([[
      local lines = {}
      for i = 1, 20 do lines[i] = 'content_' .. i end
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      vim.wo.signcolumn = 'yes'
      vim.wo.foldcolumn = '0'
      vim.wo.wrap = false
      vim.wo.cursorline = false
      vim.api.nvim_win_set_cursor(0, { 6, 0 })
      return vim.api.nvim_get_current_win()
    ]])
  end)

  after_each(function()
    if screen then
      screen:close()
      screen = nil
    end
  end)

  local function attach()
    screen:exec("require('codediff.ui.conflict').attach_gutter(...)", { win })
  end

  local function detach()
    screen:exec("require('codediff.ui.conflict').detach_gutter(...)", { win })
  end

  local function set_column(value)
    screen:exec("vim.wo.statuscolumn = ...", { value })
  end

  local function column()
    return screen:exec("return vim.wo.statuscolumn")
  end

  local function snapshot()
    screen:flush()
    local rows = {}
    for row = 1, 12 do
      rows[row] = screen:text(row, 1, 35)
    end
    return rows
  end

  for _, options in ipairs({
    { name = "no numbers", number = false, relativenumber = false },
    { name = "absolute numbers", number = true, relativenumber = false },
    { name = "relative numbers", number = false, relativenumber = true },
    { name = "hybrid numbers", number = true, relativenumber = true },
    { name = "wide hybrid numbers", number = true, relativenumber = true, numberwidth = 7 },
    { name = "fold column", number = true, relativenumber = true, foldcolumn = "2" },
    { name = "multiple sign slots", number = true, relativenumber = true, signcolumn = "yes:2" },
    { name = "signs in the number column", number = true, relativenumber = true, signcolumn = "number" },
    { name = "a sign on the hybrid cursor row", number = true, relativenumber = true, signcolumn = "number", cursor = 3 },
    { name = "hidden signs", number = true, relativenumber = true, signcolumn = "no" },
  }) do
    it("matches native rendering with " .. options.name, function()
      screen:exec(
        [[
        local options = ...
        for name, value in pairs(options) do
          if name ~= 'name' and name ~= 'cursor' then vim.wo[name] = value end
        end
        if options.cursor then vim.api.nvim_win_set_cursor(0, { options.cursor, 0 }) end
        local ns = vim.api.nvim_create_namespace('test-other-signs')
        vim.api.nvim_buf_set_extmark(0, ns, 2, 0, { sign_text = '!!', sign_hl_group = 'DiagnosticWarn' })
      ]],
        { options }
      )
      local native = snapshot()
      attach()
      assert.same(native, snapshot(), "attaching must not change native columns")
      detach()
      assert.same(native, snapshot(), "detaching must restore native columns")
    end)
  end

  it("preserves folded and wrapped rows", function()
    screen:exec([[
      vim.wo.number = true
      vim.wo.relativenumber = true
      vim.wo.foldcolumn = '1'
      vim.wo.foldmethod = 'manual'
      vim.wo.wrap = true
      vim.api.nvim_buf_set_lines(0, 0, 1, false, { string.rep('wrapped ', 15) })
      vim.cmd('3,5fold')
      vim.api.nvim_win_set_cursor(0, { 6, 0 })
    ]])
    local native = snapshot()
    attach()
    assert.same(native, snapshot())
  end)

  it("follows number option changes after attaching", function()
    attach()
    screen:exec("vim.wo.number = true; vim.wo.relativenumber = true")
    local attached = snapshot()
    detach()
    assert.same(snapshot(), attached)
  end)

  it("uses each drawing window's number options and cursor", function()
    local other = screen:exec([[
      vim.wo.number = true
      vim.wo.relativenumber = false
      vim.cmd('rightbelow vsplit')
      vim.wo.number = false
      vim.wo.relativenumber = true
      vim.api.nvim_win_set_cursor(0, { 10, 0 })
      return vim.api.nvim_get_current_win()
    ]])
    for _, focus in ipairs({ win, other }) do
      screen:exec(
        [[
        local first, second, focus = ...
        local conflict = require('codediff.ui.conflict')
        conflict.detach_gutter(first)
        conflict.detach_gutter(second)
        vim.api.nvim_set_current_win(focus)
      ]],
        { win, other, focus }
      )
      screen:flush()
      local native = {}
      for row = 1, 12 do
        native[row] = screen:text(row, 1, 80)
      end
      screen:exec("require('codediff.ui.conflict').attach_gutter(...)", { win, other })
      screen:flush()
      screen:expect_rows(1, 1, native, "different per-window number options")
    end
  end)

  it("leaves an existing custom statuscolumn untouched", function()
    set_column("USER %C%s%l")
    local native = snapshot()
    attach()
    assert.equals("USER %C%s%l", column())
    assert.same(native, snapshot())
    detach()
    assert.equals("USER %C%s%l", column())
  end)

  it("does not restore a configuration it declined to own", function()
    set_column("USER_A %l")
    attach()
    set_column("USER_B %l")
    detach()
    assert.equals("USER_B %l", column())
  end)

  it("does not overwrite a replacement installed while attached", function()
    attach()
    set_column("NEW_OWNER %l")
    detach()
    assert.equals("NEW_OWNER %l", column())
  end)

  it("does not reclaim a user's replacement on a repeated attach", function()
    attach()
    set_column("NEW_OWNER %l")
    attach()
    assert.equals("NEW_OWNER %l", column())
    detach()
    assert.equals("NEW_OWNER %l", column())
  end)

  it("attaches and detaches repeatedly without losing the original option", function()
    for _ = 1, 3 do
      attach()
      attach()
      detach()
      detach()
      assert.equals("", column())
    end
  end)
end)
