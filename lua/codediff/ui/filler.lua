local M = {}

local config = require("codediff.config")
local highlights = require("codediff.ui.highlights")

local max_width = 500
local cached_text
local cached_line

local function prefix_within_width(text, width)
  local result = ""

  for index = 0, vim.fn.strchars(text) - 1 do
    local candidate = result .. vim.fn.strcharpart(text, index, 1)
    if vim.fn.strwidth(candidate) > width then
      return result
    end
    result = candidate
  end

  return result
end

local function build_line(text)
  if text == "" then
    return ""
  end

  local text_width = vim.fn.strwidth(text)
  local repetitions = math.floor(max_width / text_width)
  local remaining_width = max_width - (text_width * repetitions)
  return string.rep(text, repetitions) .. prefix_within_width(text, remaining_width)
end

local function get_line()
  local text = config.options.diff.filler_text
  if text ~= cached_text then
    cached_text = text
    cached_line = build_line(text)
  end
  return cached_line
end

--- Return virtual-line counts indexed by the one-based line anchor.
function M.get_virt_line_counts(bufnr)
  local counts = {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return counts
  end

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, highlights.ns_filler, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    local details = mark[4]
    local count = details and details.virt_lines and #details.virt_lines or 0
    if count > 0 then
      local anchor = details.virt_lines_above and mark[2] or mark[2] + 1
      counts[anchor] = (counts[anchor] or 0) + count
    end
  end
  return counts
end

-- Insert virtual filler lines using extmarks
function M.place(bufnr, after_line_0idx, count, opts)
  if count <= 0 then
    return
  end

  opts = opts or {}
  local above = opts.above or false
  if after_line_0idx < 0 then
    after_line_0idx = 0
    above = true
  end

  local line = get_line()
  local virt_lines = {}
  for index = 1, count do
    virt_lines[index] = line == "" and {} or { { line, "CodeDiffFiller" } }
  end

  return vim.api.nvim_buf_set_extmark(bufnr, highlights.ns_filler, after_line_0idx, 0, {
    virt_lines = virt_lines,
    virt_lines_above = above,
    priority = opts.priority,
  })
end

return M
