local M = {}

local highlights = require("codediff.ui.highlights")

local ns_highlight = highlights.ns_highlight

local function format_hunk_header(orig_start, orig_count, mod_start, mod_count)
  return string.format("@@ -%d,%d +%d,%d @@", orig_start, orig_count, mod_start, mod_count)
end

local function utf16_col_to_byte_col(line, utf16_col)
  if not line or utf16_col <= 1 then
    return utf16_col
  end
  local ok, byte_idx = pcall(vim.str_byteindex, line, utf16_col - 1, true)
  if ok then
    return byte_idx + 1
  end
  return utf16_col
end

---@param buf integer
---@param original_lines string[]
---@param modified_lines string[]
---@param diff_result table
---@param opts table?
function M.render(buf, original_lines, modified_lines, diff_result, opts)
  opts = opts or {}
  local context = opts.context or 3

  local lines = {}
  local highlights_queue = {}
  local char_highlights_queue = {}

  for _, change in ipairs(diff_result.changes) do
    local orig_start = change.original.start_line
    local orig_end = change.original.end_line
    local mod_start = change.modified.start_line
    local mod_end = change.modified.end_line

    local context_start_orig = math.max(1, orig_start - context)
    local context_end_orig = math.min(#original_lines + 1, orig_end + context)

    local orig_count = context_end_orig - context_start_orig
    local mod_count = (mod_end - mod_start) + (context * 2)

    local header = format_hunk_header(context_start_orig, orig_count, mod_start - context, mod_count)
    table.insert(lines, header)
    table.insert(highlights_queue, {
      line_idx = #lines - 1,
      hl_group = "CodeDiffUnifiedHeader",
    })

    for i = context_start_orig, orig_start - 1 do
      if original_lines[i] then
        table.insert(lines, " " .. original_lines[i])
      end
    end

    local deletion_line_map = {}
    for i = orig_start, orig_end - 1 do
      if original_lines[i] then
        local line = "-" .. original_lines[i]
        table.insert(lines, line)
        local buffer_line_idx = #lines - 1
        deletion_line_map[i] = buffer_line_idx
        table.insert(highlights_queue, {
          line_idx = buffer_line_idx,
          hl_group = "CodeDiffLineDelete",
        })
      end
    end

    local insertion_line_map = {}
    for i = mod_start, mod_end - 1 do
      if modified_lines[i] then
        local line = "+" .. modified_lines[i]
        table.insert(lines, line)
        local buffer_line_idx = #lines - 1
        insertion_line_map[i] = buffer_line_idx
        table.insert(highlights_queue, {
          line_idx = buffer_line_idx,
          hl_group = "CodeDiffLineInsert",
        })
      end
    end

    if change.inner_changes then
      for _, inner in ipairs(change.inner_changes) do
        if inner.original then
          local orig_range = inner.original
          local src_line = orig_range.start_line
          local buffer_line_idx = deletion_line_map[src_line]

          if buffer_line_idx and original_lines[src_line] then
            local line_text = original_lines[src_line]
            local start_col = utf16_col_to_byte_col(line_text, orig_range.start_col)
            local end_col = utf16_col_to_byte_col(line_text, orig_range.end_col)

            start_col = start_col + 1
            end_col = end_col + 1

            table.insert(char_highlights_queue, {
              line_idx = buffer_line_idx,
              start_col = start_col - 1,
              end_col = end_col - 1,
              hl_group = "CodeDiffCharDelete",
            })
          end
        end

        if inner.modified then
          local mod_range = inner.modified
          local src_line = mod_range.start_line
          local buffer_line_idx = insertion_line_map[src_line]

          if buffer_line_idx and modified_lines[src_line] then
            local line_text = modified_lines[src_line]
            local start_col = utf16_col_to_byte_col(line_text, mod_range.start_col)
            local end_col = utf16_col_to_byte_col(line_text, mod_range.end_col)

            start_col = start_col + 1
            end_col = end_col + 1

            table.insert(char_highlights_queue, {
              line_idx = buffer_line_idx,
              start_col = start_col - 1,
              end_col = end_col - 1,
              hl_group = "CodeDiffCharInsert",
            })
          end
        end
      end
    end

    for i = orig_end, context_end_orig - 1 do
      if original_lines[i] then
        table.insert(lines, " " .. original_lines[i])
      end
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  for _, hl in ipairs(highlights_queue) do
    vim.api.nvim_buf_set_extmark(buf, ns_highlight, hl.line_idx, 0, {
      end_line = hl.line_idx + 1,
      end_col = 0,
      hl_group = hl.hl_group,
      hl_eol = true,
      priority = 100,
    })
  end

  for _, hl in ipairs(char_highlights_queue) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns_highlight, hl.line_idx, hl.start_col, {
      end_col = hl.end_col,
      hl_group = hl.hl_group,
      priority = 200,
    })
  end

  return diff_result
end

return M
