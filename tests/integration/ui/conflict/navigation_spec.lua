local conflict = require("codediff.ui.conflict")
local lifecycle = require("codediff.ui.lifecycle")

describe("conflict navigation", function()
  local original_get_session
  local tabpage
  local session
  local buffers

  local function new_buffer(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    buffers[#buffers + 1] = bufnr
    return bufnr
  end

  before_each(function()
    original_get_session = lifecycle.get_session
    tabpage = vim.api.nvim_get_current_tabpage()
    buffers = {}

    local lines = { "one", "two", "three", "four", "five" }
    local blocks = {
      {
        base_range = { start_line = 1, end_line = 2 },
        result_range = { start_line = 1, end_line = 2 },
        output1_range = { start_line = 1, end_line = 2 },
        output2_range = { start_line = 1, end_line = 2 },
      },
      {
        base_range = { start_line = 4, end_line = 5 },
        result_range = { start_line = 4, end_line = 5 },
        output1_range = { start_line = 4, end_line = 5 },
        output2_range = { start_line = 4, end_line = 5 },
      },
    }
    session = {
      result_bufnr = new_buffer(vim.deepcopy(lines)),
      original_bufnr = new_buffer(vim.deepcopy(lines)),
      modified_bufnr = new_buffer(vim.deepcopy(lines)),
      result_base_lines = vim.deepcopy(lines),
      conflict_blocks = blocks,
    }
    lifecycle.get_session = function(candidate)
      return candidate == tabpage and session or nil
    end
    conflict.initialize_tracking(session.result_bufnr, blocks)
  end)

  after_each(function()
    lifecycle.get_session = original_get_session
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  it("moves forward, wraps, and moves backward across active blocks", function()
    vim.api.nvim_set_current_buf(session.original_bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    conflict.navigate_next_conflict(tabpage)
    assert.equals(4, vim.api.nvim_win_get_cursor(0)[1])

    conflict.navigate_next_conflict(tabpage)
    assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])

    conflict.navigate_prev_conflict(tabpage)
    assert.equals(4, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)
