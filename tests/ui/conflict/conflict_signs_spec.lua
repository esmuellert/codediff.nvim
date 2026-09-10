local conflict = require("codediff.ui.conflict")
local lifecycle = require("codediff.ui.lifecycle")
local tracking = require("codediff.ui.conflict.tracking")
local highlights = require("codediff.ui.highlights")

describe("conflict signs", function()
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

  local function sign_highlight(bufnr, namespace)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
    assert.is_true(#marks > 0, "expected a conflict sign")
    return marks[1][4].sign_hl_group
  end

  before_each(function()
    original_get_session = lifecycle.get_session
    tabpage = vim.api.nvim_get_current_tabpage()
    buffers = {}

    local block = {
      base_range = { start_line = 1, end_line = 2 },
      result_range = { start_line = 1, end_line = 2 },
      output1_range = { start_line = 1, end_line = 2 },
      output2_range = { start_line = 1, end_line = 2 },
    }
    session = {
      result_bufnr = new_buffer({ "base" }),
      original_bufnr = new_buffer({ "incoming" }),
      modified_bufnr = new_buffer({ "current" }),
      result_base_lines = { "base" },
      merge_base_lines = { "base" },
      conflict_blocks = { block },
    }
    lifecycle.get_session = function(candidate)
      return candidate == tabpage and session or nil
    end
    conflict.initialize_tracking(session.result_bufnr, session.conflict_blocks)
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

  it("changes input and Result signs after accepting one side", function()
    conflict.refresh(session)
    assert.equals("CodeDiffConflictSign", sign_highlight(session.original_bufnr, highlights.ns_conflict))
    assert.equals("CodeDiffConflictSign", sign_highlight(session.modified_bufnr, highlights.ns_conflict))
    assert.equals("CodeDiffConflictSign", sign_highlight(session.result_bufnr, tracking.result_signs_ns))

    vim.api.nvim_set_current_buf(session.original_bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    assert.is_true(conflict.accept_incoming(tabpage))

    assert.equals("CodeDiffConflictSignAccepted", sign_highlight(session.original_bufnr, highlights.ns_conflict))
    assert.equals("CodeDiffConflictSignRejected", sign_highlight(session.modified_bufnr, highlights.ns_conflict))
    assert.equals("CodeDiffConflictSignResolved", sign_highlight(session.result_bufnr, tracking.result_signs_ns))
  end)
end)
