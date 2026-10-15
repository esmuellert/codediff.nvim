local conflict = require("codediff.ui.conflict")
local lifecycle = require("codediff.ui.lifecycle")
local inline = require("codediff.ui.inline")

describe("conflict hover preview", function()
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

  -- One conflict block whose current (right) side is `current_lines`, against `base_lines`.
  local function configure(base_lines, current_lines, base_range, current_range)
    local block = {
      base_range = base_range,
      result_range = base_range,
      output1_range = { start_line = 1, end_line = 2 },
      output2_range = current_range,
    }
    session = {
      result_bufnr = new_buffer(vim.deepcopy(base_lines)),
      original_bufnr = new_buffer({ "incoming" }),
      modified_bufnr = new_buffer(current_lines),
      result_base_lines = vim.deepcopy(base_lines),
      merge_base_lines = vim.deepcopy(base_lines),
      conflict_blocks = { block },
    }
    lifecycle.get_session = function(candidate)
      return candidate == tabpage and session or nil
    end
    conflict.initialize_tracking(session.result_bufnr, session.conflict_blocks)
    vim.api.nvim_set_current_buf(session.modified_bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
  end

  -- Virtual lines of the preview as { row = 0-based anchor, text = trimmed line }.
  local function virtual_lines(win)
    local found = {}
    local marks = vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(win), inline.ns_inline, 0, -1, { details = true })
    for _, mark in ipairs(marks) do
      for _, chunks in ipairs(mark[4].virt_lines or {}) do
        local text = table.concat(vim.tbl_map(function(chunk)
          return chunk[1]
        end, chunks))
        table.insert(found, { row = mark[2], text = (text:gsub("%s+$", "")) })
      end
    end
    return found
  end

  local function topfill(win)
    return vim.api.nvim_win_call(win, vim.fn.winsaveview).topfill
  end

  before_each(function()
    original_get_session = lifecycle.get_session
    tabpage = vim.api.nvim_get_current_tabpage()
    buffers = {}
  end)

  after_each(function()
    lifecycle.get_session = original_get_session
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        vim.api.nvim_win_close(win, true)
      end
    end
    vim.wo.scrollbind = false
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  it("shows the focused side with the replaced base line above it", function()
    configure({ "base" }, { "current" }, { start_line = 1, end_line = 2 }, { start_line = 1, end_line = 2 })
    vim.wo.scrollbind = true

    assert.is_true(conflict.toggle_hover(tabpage))
    local win = session._hover_win
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.same({ "current" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false))
    assert.same({ { row = 0, text = "base" } }, virtual_lines(win))
    assert.equals(1, topfill(win))
    assert.equals(2, vim.api.nvim_win_get_height(win))
    assert.is_false(vim.wo[win].scrollbind)
    assert.equals(" Ours (Current) vs Base ", vim.api.nvim_win_get_config(win).title[1][1])

    assert.is_false(conflict.toggle_hover(tabpage))
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("shows a side added on an empty base as inserted lines only", function()
    configure({ "context" }, { "added" }, { start_line = 1, end_line = 1 }, { start_line = 1, end_line = 2 })

    assert.is_true(conflict.toggle_hover(tabpage))
    local win = session._hover_win
    assert.same({}, virtual_lines(win))
    local marks = vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(win), inline.ns_inline, 0, -1, { details = true })
    assert.is_true(#marks > 0)
    assert.equals("CodeDiffLineInsert", marks[1][4].hl_group)
    assert.equals(0, topfill(win))
    assert.equals(1, vim.api.nvim_win_get_height(win))
  end)

  it("keeps a deletion at the end of the hunk below the side's last line", function()
    configure({ "a", "b", "c" }, { "A", "b" }, { start_line = 1, end_line = 4 }, { start_line = 1, end_line = 3 })

    assert.is_true(conflict.toggle_hover(tabpage))
    local win = session._hover_win
    assert.same({ "A", "b", "" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false))
    assert.same({ { row = 0, text = "a" }, { row = 2, text = "c" } }, virtual_lines(win))
    assert.equals(1, topfill(win))
    assert.equals(5, vim.api.nvim_win_get_height(win))
  end)

  it("does nothing outside a conflict or in the result pane", function()
    configure({ "base", "tail" }, { "current", "tail" }, { start_line = 1, end_line = 2 }, { start_line = 1, end_line = 2 })

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    assert.is_false(conflict.toggle_hover(tabpage))
    vim.api.nvim_set_current_buf(session.result_bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    assert.is_false(conflict.toggle_hover(tabpage))
    assert.is_nil(session._hover_win)
  end)
end)
