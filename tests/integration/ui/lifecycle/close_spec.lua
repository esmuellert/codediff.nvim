local commands = require("codediff.commands")
local lifecycle = require("codediff.ui.lifecycle")
local view = require("codediff.ui.view")

local created_buffers = {}
local created_files = {}

local function reset_tabs()
  vim.cmd("tabnew")
  vim.cmd("tabonly!")
end

local function create_session(exit_on_close)
  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  vim.cmd("vsplit")
  local windows = vim.api.nvim_tabpage_list_wins(tabpage)
  local original_bufnr = vim.api.nvim_create_buf(false, true)
  local modified_bufnr = vim.api.nvim_create_buf(false, true)
  table.insert(created_buffers, original_bufnr)
  table.insert(created_buffers, modified_bufnr)
  vim.api.nvim_win_set_buf(windows[1], original_bufnr)
  vim.api.nvim_win_set_buf(windows[2], modified_bufnr)
  lifecycle.create_session(tabpage, {
    original = "original.txt",
    modified = "modified.txt",
    exit_on_close = exit_on_close,
  }, {
    original_bufnr = original_bufnr,
    modified_bufnr = modified_bufnr,
    original_win = windows[1],
    modified_win = windows[2],
    lines_diff = {},
  })
  return tabpage
end

local function create_file(lines)
  local path = vim.fn.tempname()
  vim.fn.writefile(lines, path)
  table.insert(created_files, path)
  return path
end

describe("CodeDiff close", function()
  before_each(function()
    lifecycle.setup()
    created_buffers = {}
    created_files = {}
    reset_tabs()
  end)

  after_each(function()
    lifecycle.cleanup_all()
    reset_tabs()
    for _, bufnr in ipairs(created_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    for _, path in ipairs(created_files) do
      vim.fn.delete(path)
    end
  end)

  it("closes only the CodeDiff tab when another tab exists", function()
    local tabpage = create_session(false)
    local close_count = 0
    local autocmd = vim.api.nvim_create_autocmd("User", {
      pattern = "CodeDiffClose",
      callback = function()
        close_count = close_count + 1
      end,
    })

    assert.is_true(lifecycle.close(tabpage))

    assert.is_false(vim.api.nvim_tabpage_is_valid(tabpage))
    assert.equals(1, #vim.api.nvim_list_tabpages())
    assert.is_nil(lifecycle.get_session(tabpage))
    assert.equals(1, close_count)
    vim.api.nvim_del_autocmd(autocmd)
  end)

  it("leaves a replacement tab when closing the last CodeDiff tab", function()
    local tabpage = create_session(false)
    vim.cmd("tabonly!")

    assert.is_true(lifecycle.close(tabpage))

    local tabs = vim.api.nvim_list_tabpages()
    assert.equals(1, #tabs)
    assert.is_not.equal(tabpage, tabs[1])
    assert.is_nil(lifecycle.get_session(tabpage))
  end)

  it("keeps the session when unsaved-change confirmation is cancelled", function()
    local tabpage = create_session(false)
    vim.cmd("tabonly!")
    local path = create_file({ "original" })
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    table.insert(created_buffers, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "modified" })
    lifecycle.track_conflict_file(tabpage, path)
    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 2
    end

    local closed = lifecycle.close(tabpage)
    vim.fn.confirm = original_confirm

    assert.is_false(closed)
    assert.is_true(vim.api.nvim_tabpage_is_valid(tabpage))
    assert.is_not_nil(lifecycle.get_session(tabpage))
    assert.equals(1, #vim.api.nvim_list_tabpages())
  end)

  it("exits Neovim only for an opted-in session", function()
    local tabpage = create_session(true)
    local original_cmd = vim.cmd
    local qall_called = false
    vim.cmd = function(command)
      if command == "qall" then
        qall_called = true
        return
      end
      return original_cmd(command)
    end

    local ok, closed = pcall(lifecycle.close, tabpage)
    vim.cmd = original_cmd

    assert.is_true(ok)
    assert.is_true(closed)
    assert.is_true(qall_called)
    assert.is_nil(lifecycle.get_session(tabpage))
  end)

  it("closes through the :CodeDiff toggle", function()
    local tabpage = create_session(false)

    commands.vscode_diff({ fargs = {} })

    assert.is_false(vim.api.nvim_tabpage_is_valid(tabpage))
    assert.is_nil(lifecycle.get_session(tabpage))
  end)

  it("stores --exit-on-close on the created session", function()
    local original = create_file({ "original" })
    local modified = create_file({ "modified" })
    local original_create = view.create
    local session_config
    view.create = function(config)
      session_config = config
    end

    local ok, err = pcall(commands.vscode_diff, {
      fargs = { "--exit-on-close", "file", original, modified },
    })
    view.create = original_create

    assert.is_true(ok, err)
    assert.is_true(session_config.exit_on_close)
  end)
end)
