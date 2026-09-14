local conflict = require("codediff.ui.conflict")
local lifecycle = require("codediff.ui.lifecycle")
local tracking = require("codediff.ui.conflict.tracking")

describe("conflict resolution commands", function()
  local original_get_session
  local original_operatorfunc
  local tabpage
  local session
  local block
  local buffers

  local function new_buffer(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    buffers[#buffers + 1] = bufnr
    return bufnr
  end

  local function configure(opts)
    local base_lines = opts.base_lines or { "base" }
    block = {
      base_range = { start_line = 1, end_line = 2 },
      result_range = { start_line = 1, end_line = 2 },
      output1_range = { start_line = 1, end_line = 2 },
      output2_range = { start_line = 1, end_line = 2 },
      inner1 = opts.inner1 or {},
      inner2 = opts.inner2 or {},
    }
    session = {
      result_bufnr = new_buffer(vim.deepcopy(base_lines)),
      original_bufnr = new_buffer(opts.incoming_lines or { "incoming" }),
      modified_bufnr = new_buffer(opts.current_lines or { "current" }),
      result_base_lines = vim.deepcopy(base_lines),
      merge_base_lines = vim.deepcopy(base_lines),
      conflict_blocks = { block },
    }
    lifecycle.get_session = function(candidate)
      return candidate == tabpage and session or nil
    end
    conflict.initialize_tracking(session.result_bufnr, session.conflict_blocks)
  end

  before_each(function()
    original_get_session = lifecycle.get_session
    original_operatorfunc = vim.go.operatorfunc
    tabpage = vim.api.nvim_get_current_tabpage()
    buffers = {}
  end)

  after_each(function()
    lifecycle.get_session = original_get_session
    vim.go.operatorfunc = original_operatorfunc
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  it("accepts the current side for the selected block", function()
    configure({})
    vim.api.nvim_set_current_buf(session.modified_bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    assert.is_true(conflict.accept_current(tabpage))
    assert.same({ "current" }, vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false))
  end)

  it("smart-combines non-overlapping edits from both sides", function()
    configure({
      base_lines = { "abc" },
      incoming_lines = { "aXbc" },
      current_lines = { "abYc" },
      inner1 = {
        {
          original = { start_line = 1, start_col = 2, end_line = 1, end_col = 2 },
          modified = { start_line = 1, start_col = 2, end_line = 1, end_col = 3 },
        },
      },
      inner2 = {
        {
          original = { start_line = 1, start_col = 3, end_line = 1, end_col = 3 },
          modified = { start_line = 1, start_col = 3, end_line = 1, end_col = 4 },
        },
      },
    })
    vim.api.nvim_set_current_buf(session.original_bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    assert.is_true(conflict.accept_both(tabpage))
    assert.same({ "aXbYc" }, vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false))
  end)

  it("concatenates both sides when smart combination is unavailable", function()
    configure({})
    vim.api.nvim_set_current_buf(session.original_bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    assert.is_true(conflict.accept_both(tabpage))
    assert.same({ "incoming", "current" }, vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false))
  end)

  it("gets the incoming side from the Result buffer", function()
    configure({})
    vim.api.nvim_set_current_buf(session.result_bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    assert.is_true(conflict.diffget_incoming(tabpage))
    assert.same({ "incoming" }, vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false))
  end)

  it("gets the current side from the Result buffer", function()
    configure({})
    vim.api.nvim_set_current_buf(session.result_bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    assert.is_true(conflict.diffget_current(tabpage))
    assert.same({ "current" }, vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false))
  end)

  it("repeats the most recently prepared resolution", function()
    local calls = 0
    local repeatable = tracking.make_repeatable(function()
      calls = calls + 1
    end)

    assert.equals("g@l", repeatable())
    conflict.run_repeatable_action("line")
    assert.equals(1, calls)
  end)
end)
