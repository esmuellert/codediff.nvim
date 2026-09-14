local config = require("codediff.config")
local core = require("codediff.ui.core")
local diff = require("codediff.core.diff")
local filler = require("codediff.ui.filler")
local highlights = require("codediff.ui.highlights")
local move = require("codediff.ui.move")

local function create_buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or { "line" })
  return bufnr
end

local function get_filler_marks(bufnr)
  return vim.api.nvim_buf_get_extmarks(bufnr, highlights.ns_filler, 0, -1, { details = true })
end

local function get_first_filler_text(bufnr)
  local virt_lines = get_filler_marks(bufnr)[1][4].virt_lines
  return virt_lines[1][1] and virt_lines[1][1][1]
end

describe("Configurable filler rendering", function()
  before_each(function()
    config.options = vim.deepcopy(config.defaults)
  end)

  it("uses slashes by default", function()
    assert.equal("╱", config.options.diff.filler_text)

    local bufnr = create_buffer()
    filler.place(bufnr, 0, 1)

    assert.equal(string.rep("╱", 500), get_first_filler_text(bufnr))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("repeats multi-character patterns to the fixed display width", function()
    config.setup({ diff = { filler_text = "界x" } })
    local bufnr = create_buffer()
    filler.place(bufnr, 0, 1)

    local text = get_first_filler_text(bufnr)
    assert.equal(500, vim.fn.strwidth(text))
    assert.equal(string.rep("界x", 166) .. "界", text)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("keeps blank alignment rows when filler text is empty", function()
    config.setup({ diff = { filler_text = "" } })
    local bufnr = create_buffer()
    filler.place(bufnr, 0, 3)

    local marks = get_filler_marks(bufnr)
    assert.equal(1, #marks)
    assert.equal(3, #marks[1][4].virt_lines)
    assert.same({ {}, {}, {} }, marks[1][4].virt_lines)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("uses configured text for side-by-side fillers", function()
    config.setup({ diff = { filler_text = ".-" } })
    local left_buf = create_buffer({ "line 1" })
    local right_buf = create_buffer({ "line 1", "added 1", "added 2" })
    local lines_diff = diff.compute_diff({ "line 1" }, { "line 1", "added 1", "added 2" })

    core.render_diff(left_buf, right_buf, { "line 1" }, { "line 1", "added 1", "added 2" }, lines_diff)

    assert.is_truthy(get_first_filler_text(left_buf):match("^%.%-%.%-"))
    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)

  it("uses configured text for merge fillers", function()
    config.setup({ diff = { filler_text = "·" } })
    local base = { "a", "b", "c" }
    local left = { "a", "left 1", "left 2", "b", "c" }
    local right = { "a", "b", "c" }
    local left_buf = create_buffer(left)
    local right_buf = create_buffer(right)

    core.render_merge_view(left_buf, right_buf, diff.compute_diff(base, left), diff.compute_diff(base, right), base, left, right)

    local marks = #get_filler_marks(left_buf) > 0 and get_filler_marks(left_buf) or get_filler_marks(right_buf)
    assert.is_true(#marks > 0)
    assert.is_truthy(marks[1][4].virt_lines[1][1][1]:match("^···"))
    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)

  it("uses configured text for move compensation fillers", function()
    config.setup({ diff = { filler_text = "~" } })
    local left_buf = create_buffer({ "a", "b", "c" })
    local right_buf = create_buffer({ "a", "b", "c" })
    local lines_diff = {
      changes = {},
      moves = {
        {
          original = { start_line = 1, end_line = 2 },
          modified = { start_line = 3, end_line = 4 },
        },
      },
    }

    move.render_moves(left_buf, right_buf, lines_diff)

    assert.is_truthy(get_first_filler_text(left_buf):match("^~~~"))
    assert.is_truthy(get_first_filler_text(right_buf):match("^~~~"))
    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)
end)
