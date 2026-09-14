-- Regression tests for Neovim's native scrollbind in CodeDiff-shaped panes.

local function make_window(lines, filler_count)
  vim.cmd("enew")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.wo.wrap = false

  if filler_count and filler_count > 0 then
    local namespace = vim.api.nvim_create_namespace("scrollbind_test")
    local virt_lines = {}
    for i = 1, filler_count do
      virt_lines[i] = { { string.format("filler %02d", i), "Comment" } }
    end
    vim.api.nvim_buf_set_extmark(bufnr, namespace, 19, 0, { virt_lines = virt_lines })
  end

  return vim.api.nvim_get_current_win()
end

local function make_content(prefix, count)
  local lines = {}
  for i = 1, count do
    lines[i] = string.format("%s%03d", prefix, i)
  end
  return lines
end

local function topline(win)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.line("w0")
  end)
end

describe("native scrollbind", function()
  local original_lines

  before_each(function()
    original_lines = vim.o.lines
    vim.o.lines = 16
    vim.cmd("tabnew")
  end)

  after_each(function()
    vim.o.lines = original_lines
    pcall(vim.cmd, "tabclose!")
  end)

  it("enables native scrollbind on both side-by-side panes", function()
    local left = make_window({ "left" })
    vim.cmd("rightbelow vsplit")
    local right = make_window({ "right" })

    vim.wo[left].scrollbind = true
    vim.wo[right].scrollbind = true

    assert.is_true(vim.wo[left].scrollbind)
    assert.is_true(vim.wo[right].scrollbind)
  end)

  it("keeps scrolling monotonic through a full-screen filler block", function()
    if vim.fn.has("nvim-0.13") ~= 1 then
      pending("requires Neovim's upstream tall virt_lines scrollbind fix")
    end

    local left = make_window(make_content("C", 60), 30)
    vim.cmd("rightbelow vsplit")
    local right_lines = make_content("C", 20)
    for i = 1, 30 do
      right_lines[#right_lines + 1] = string.format("I%03d", i)
    end
    for i = 21, 60 do
      right_lines[#right_lines + 1] = string.format("C%03d", i)
    end
    local right = make_window(right_lines)

    vim.wo[left].scrollbind = true
    vim.wo[right].scrollbind = true
    vim.api.nvim_set_current_win(right)
    vim.cmd("syncbind")

    local previous = 0
    local max_backjump = 0
    for _ = 1, 40 do
      vim.cmd("normal! \5")
      local current = topline(left)
      if current < previous then
        max_backjump = math.max(max_backjump, previous - current)
      end
      previous = current
    end

    assert.is_true(max_backjump <= 1, "native scrollbind must not oscillate; max backward jump was " .. max_backjump)
  end)
end)
