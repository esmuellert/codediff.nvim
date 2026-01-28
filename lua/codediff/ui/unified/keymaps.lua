local M = {}

local config = require("codediff.config")

local function find_next_hunk(buf, current_line)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i = current_line + 1, #lines do
    if lines[i]:match("^@@") then
      return i - 1
    end
  end
  return nil
end

local function find_prev_hunk(buf, current_line)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i = current_line - 1, 1, -1 do
    if lines[i]:match("^@@") then
      return i - 1
    end
  end
  return nil
end

---@param buf integer
function M.setup(buf)
  local opts = { buffer = buf, silent = true }
  local keymaps = config.options.keymaps.view

  vim.keymap.set("n", keymaps.next_hunk, function()
    local next = find_next_hunk(buf, vim.fn.line("."))
    if next then
      vim.api.nvim_win_set_cursor(0, { next + 1, 0 })
    end
  end, opts)

  vim.keymap.set("n", keymaps.prev_hunk, function()
    local prev = find_prev_hunk(buf, vim.fn.line("."))
    if prev then
      vim.api.nvim_win_set_cursor(0, { prev + 1, 0 })
    end
  end, opts)

  vim.keymap.set("n", keymaps.quit, function()
    vim.cmd("tabclose")
  end, opts)
end

return M
