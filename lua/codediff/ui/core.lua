-- Core diff rendering algorithm
local M = {}

local highlights = require("codediff.ui.highlights")

-- Namespace references
local ns_highlight = highlights.ns_highlight
local ns_filler = highlights.ns_filler
local ns_conflict = highlights.ns_conflict

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- Check if a range is empty (start and end are the same position)
local function is_empty_range(range)
  return range.start_line == range.end_line and range.start_col == range.end_col
end

-- Check if a column position is past the visible line content
local function is_past_line_content(line_number, column, lines)
  if line_number < 1 or line_number > #lines then
    return true
  end
  local line_content = lines[line_number]
  return column > #line_content
end

-- Insert virtual filler lines using extmarks
local function insert_filler_lines(bufnr, after_line_0idx, count)
  if count <= 0 then
    return
  end

  if after_line_0idx < 0 then
    after_line_0idx = 0
  end

  local virt_lines_content = {}
  local filler_text = string.rep("╱", 500)

  for _ = 1, count do
    table.insert(virt_lines_content, { { filler_text, "CodeDiffFiller" } })
  end

  vim.api.nvim_buf_set_extmark(bufnr, ns_filler, after_line_0idx, 0, {
    virt_lines = virt_lines_content,
    virt_lines_above = false,
  })
end

-- ============================================================================
-- Step 1: Line-Level Highlights
-- ============================================================================

local function apply_line_highlights(bufnr, line_range, hl_group)
  if line_range.end_line <= line_range.start_line then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for line = line_range.start_line, line_range.end_line - 1 do
    if line > line_count then
      break
    end

    local line_idx = line - 1

    vim.api.nvim_buf_set_extmark(bufnr, ns_highlight, line_idx, 0, {
      end_line = line_idx + 1,
      end_col = 0,
      hl_group = hl_group,
      hl_eol = true,
      priority = 100,
    })
  end
end

-- ============================================================================
-- Step 2: Character-Level Highlights
-- ============================================================================

-- Convert UTF-16 code unit offset to UTF-8 byte offset
-- The diff algorithm returns UTF-16 positions (VSCode/JavaScript native)
-- but Neovim expects byte positions for highlighting
-- For ASCII text, UTF-16 index equals byte index (no change)
-- utf16_col: 1-based UTF-16 code unit position
-- Returns: 1-based byte position
local function utf16_col_to_byte_col(line, utf16_col)
  if not line or utf16_col <= 1 then
    return utf16_col
  end
  -- vim.str_byteindex uses 0-based indexing, our columns are 1-based
  local ok, byte_idx = pcall(vim.str_byteindex, line, utf16_col - 1, true)
  if ok then
    return byte_idx + 1
  end
  -- Fallback: return original column if conversion fails
  return utf16_col
end

local function apply_char_highlight(bufnr, char_range, hl_group, lines)
  local start_line = char_range.start_line
  local start_col = char_range.start_col
  local end_line = char_range.end_line
  local end_col = char_range.end_col

  if is_empty_range(char_range) then
    return
  end

  if is_past_line_content(start_line, start_col, lines) then
    return
  end

  -- Convert UTF-16 column positions to byte positions for Neovim
  if start_line >= 1 and start_line <= #lines then
    local line_content = lines[start_line]
    start_col = utf16_col_to_byte_col(line_content, start_col)
  end

  if end_line >= 1 and end_line <= #lines then
    local line_content = lines[end_line]
    end_col = utf16_col_to_byte_col(line_content, end_col)
    end_col = math.min(end_col, #line_content + 1)
  end

  -- Verify buffer has enough lines (buffer may have changed since diff was computed)
  local buf_line_count = vim.api.nvim_buf_line_count(bufnr)
  if start_line > buf_line_count or end_line > buf_line_count then
    return
  end

  if start_line == end_line then
    local line_idx = start_line - 1
    if line_idx >= 0 then
      -- Additional safety: verify column is within current buffer line length
      local ok = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_highlight, line_idx, start_col - 1, {
        end_col = end_col - 1,
        hl_group = hl_group,
        priority = 200,
      })
      if not ok then
        -- Column out of range, skip this highlight
        return
      end
    end
  else
    local first_line_idx = start_line - 1
    if first_line_idx >= 0 then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_highlight, first_line_idx, start_col - 1, {
        end_line = first_line_idx + 1,
        end_col = 0,
        hl_group = hl_group,
        priority = 200,
      })
    end

    for line = start_line + 1, end_line - 1 do
      local line_idx = line - 1
      if line_idx >= 0 and line <= buf_line_count then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_highlight, line_idx, 0, {
          end_line = line_idx + 1,
          end_col = 0,
          hl_group = hl_group,
          priority = 200,
        })
      end
    end

    if end_col > 1 or end_line ~= start_line then
      local last_line_idx = end_line - 1
      if last_line_idx >= 0 and last_line_idx ~= first_line_idx and end_line <= buf_line_count then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_highlight, last_line_idx, 0, {
          end_col = end_col - 1,
          hl_group = hl_group,
          priority = 200,
        })
      end
    end
  end
end

-- ============================================================================
-- Step 3: Filler Line Calculation
-- ============================================================================

local function calculate_fillers(mapping, original_lines, _modified_lines, last_orig_line, last_mod_line)
  local fillers = {}

  last_orig_line = last_orig_line or mapping.original.start_line
  last_mod_line = last_mod_line or mapping.modified.start_line

  if not mapping.inner_changes or #mapping.inner_changes == 0 then
    local mapping_orig_lines = mapping.original.end_line - mapping.original.start_line
    local mapping_mod_lines = mapping.modified.end_line - mapping.modified.start_line

    if mapping_orig_lines > mapping_mod_lines then
      local diff = mapping_orig_lines - mapping_mod_lines
      table.insert(fillers, {
        buffer = "modified",
        after_line = mapping.modified.start_line - 1,
        count = diff,
      })
    elseif mapping_mod_lines > mapping_orig_lines then
      local diff = mapping_mod_lines - mapping_orig_lines
      table.insert(fillers, {
        buffer = "original",
        after_line = mapping.original.start_line - 1,
        count = diff,
      })
    end
    return fillers, mapping.original.end_line, mapping.modified.end_line
  end

  local alignments = {}
  local first = true

  local function handle_gap_alignment(orig_line_exclusive, mod_line_exclusive)
    local orig_gap = orig_line_exclusive - last_orig_line
    local mod_gap = mod_line_exclusive - last_mod_line

    if orig_gap > 0 or mod_gap > 0 then
      table.insert(alignments, {
        orig_start = last_orig_line,
        orig_end = orig_line_exclusive,
        mod_start = last_mod_line,
        mod_end = mod_line_exclusive,
        orig_len = orig_gap,
        mod_len = mod_gap,
      })
      last_orig_line = orig_line_exclusive
      last_mod_line = mod_line_exclusive
    end
  end

  handle_gap_alignment(mapping.original.start_line, mapping.modified.start_line)

  local function emit_alignment(orig_line_exclusive, mod_line_exclusive)
    if orig_line_exclusive < last_orig_line or mod_line_exclusive < last_mod_line then
      return
    end

    if first then
      first = false
    elseif orig_line_exclusive == last_orig_line or mod_line_exclusive == last_mod_line then
      return
    end

    local orig_range_len = orig_line_exclusive - last_orig_line
    local mod_range_len = mod_line_exclusive - last_mod_line

    if orig_range_len > 0 or mod_range_len > 0 then
      table.insert(alignments, {
        orig_start = last_orig_line,
        orig_end = orig_line_exclusive,
        mod_start = last_mod_line,
        mod_end = mod_line_exclusive,
        orig_len = orig_range_len,
        mod_len = mod_range_len,
      })
    end

    last_orig_line = orig_line_exclusive
    last_mod_line = mod_line_exclusive
  end

  for _, inner in ipairs(mapping.inner_changes) do
    if inner.original.start_col > 1 and inner.modified.start_col > 1 then
      emit_alignment(inner.original.start_line, inner.modified.start_line)
    end

    local orig_line_len = original_lines[inner.original.end_line] and #original_lines[inner.original.end_line] or 0
    if inner.original.end_col <= orig_line_len then
      emit_alignment(inner.original.end_line, inner.modified.end_line)
    end
  end

  emit_alignment(mapping.original.end_line, mapping.modified.end_line)

  for _, align in ipairs(alignments) do
    local line_diff = align.mod_len - align.orig_len

    if line_diff > 0 then
      table.insert(fillers, {
        buffer = "original",
        after_line = align.orig_end - 1,
        count = line_diff,
      })
    elseif line_diff < 0 then
      table.insert(fillers, {
        buffer = "modified",
        after_line = align.mod_end - 1,
        count = -line_diff,
      })
    end
  end

  return fillers, last_orig_line, last_mod_line
end

-- ============================================================================
-- Main Rendering Function
-- ============================================================================

-- Render diff highlights and fillers
-- Assumes buffer content is already set by caller
function M.render_diff(left_bufnr, right_bufnr, original_lines, modified_lines, lines_diff)
  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(left_bufnr, ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(right_bufnr, ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(left_bufnr, ns_filler, 0, -1)
  vim.api.nvim_buf_clear_namespace(right_bufnr, ns_filler, 0, -1)

  local total_left_fillers = 0
  local total_right_fillers = 0

  local last_orig_line = 1
  local last_mod_line = 1

  for _, mapping in ipairs(lines_diff.changes) do
    local orig_is_empty = (mapping.original.end_line <= mapping.original.start_line)
    local mod_is_empty = (mapping.modified.end_line <= mapping.modified.start_line)

    if not orig_is_empty then
      apply_line_highlights(left_bufnr, mapping.original, "CodeDiffLineDelete")
    end

    if not mod_is_empty then
      apply_line_highlights(right_bufnr, mapping.modified, "CodeDiffLineInsert")
    end

    if mapping.inner_changes then
      for _, inner in ipairs(mapping.inner_changes) do
        if not is_empty_range(inner.original) then
          apply_char_highlight(left_bufnr, inner.original, "CodeDiffCharDelete", original_lines)
        end

        if not is_empty_range(inner.modified) then
          apply_char_highlight(right_bufnr, inner.modified, "CodeDiffCharInsert", modified_lines)
        end
      end
    end

    local fillers, new_last_orig, new_last_mod = calculate_fillers(mapping, original_lines, modified_lines, last_orig_line, last_mod_line)

    last_orig_line = new_last_orig
    last_mod_line = new_last_mod

    for _, filler in ipairs(fillers) do
      if filler.buffer == "original" then
        insert_filler_lines(left_bufnr, filler.after_line - 1, filler.count)
        total_left_fillers = total_left_fillers + filler.count
      else
        insert_filler_lines(right_bufnr, filler.after_line - 1, filler.count)
        total_right_fillers = total_right_fillers + filler.count
      end
    end
  end

  return {
    left_fillers = total_left_fillers,
    right_fillers = total_right_fillers,
  }
end

-- ============================================================================
-- Single Buffer Rendering (for merge view)
-- ============================================================================

-- Render diff highlights for a single buffer
-- Used in merge view where each buffer shows diff against base independently
-- bufnr: buffer number to render
-- diff: the diff result (same format as lines_diff from compute_diff)
-- side: "original" or "modified" - which side of the diff this buffer represents
--       "original" = deletions (red highlights)
--       "modified" = insertions (green highlights)
function M.render_single_buffer(bufnr, diff, side)
  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(bufnr, ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_filler, 0, -1)

  -- Get buffer lines for character highlight calculations
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Determine highlight groups based on side
  local line_hl, char_hl
  if side == "original" then
    line_hl = "CodeDiffLineDelete"
    char_hl = "CodeDiffCharDelete"
  else
    line_hl = "CodeDiffLineInsert"
    char_hl = "CodeDiffCharInsert"
  end

  for _, mapping in ipairs(diff.changes) do
    -- Get the range for our side
    local range = mapping[side]
    if not range then
      goto continue
    end

    local is_empty = (range.end_line <= range.start_line)

    -- Apply line highlights
    if not is_empty then
      apply_line_highlights(bufnr, range, line_hl)
    end

    -- Apply character highlights from inner changes
    if mapping.inner_changes then
      for _, inner in ipairs(mapping.inner_changes) do
        local inner_range = inner[side]
        if inner_range and not is_empty_range(inner_range) then
          apply_char_highlight(bufnr, inner_range, char_hl, lines)
        end
      end
    end

    ::continue::
  end
end

-- ============================================================================
-- Merge View Rendering (3-way merge with alignment)
-- ============================================================================

-- Render merge view with proper alignment between left and right buffers
-- Both buffers show diff against base, with filler lines to align corresponding changes
-- left_bufnr: buffer showing input1 (incoming/theirs :3)
-- right_bufnr: buffer showing input2 (current/ours :2)
-- base_to_left_diff: diff from base to input1
-- base_to_right_diff: diff from base to input2
-- base_lines: array of base content lines
-- left_lines_content: array of input1 content lines
-- right_lines_content: array of input2 content lines
function M.render_merge_view(left_bufnr, right_bufnr, base_to_left_diff, base_to_right_diff, base_lines, left_lines_content, right_lines_content)
  local merge_alignment = require("codediff.ui.merge_alignment")

  -- Clear existing highlights and fillers
  vim.api.nvim_buf_clear_namespace(left_bufnr, ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(left_bufnr, ns_filler, 0, -1)
  vim.api.nvim_buf_clear_namespace(left_bufnr, ns_conflict, 0, -1)
  vim.api.nvim_buf_clear_namespace(right_bufnr, ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(right_bufnr, ns_filler, 0, -1)
  vim.api.nvim_buf_clear_namespace(right_bufnr, ns_conflict, 0, -1)

  -- Get buffer lines for character highlight calculations
  local left_lines = vim.api.nvim_buf_get_lines(left_bufnr, 0, -1, false)
  local right_lines = vim.api.nvim_buf_get_lines(right_bufnr, 0, -1, false)

  -- Compute alignments to identify conflict regions (where both sides have changes)
  local alignments, conflict_left_changes, conflict_right_changes =
    merge_alignment.compute_merge_fillers_and_conflicts(base_to_left_diff, base_to_right_diff, base_lines, left_lines_content, right_lines_content)

  -- Render highlights ONLY for conflict regions (where both left and right modified the same base region)
  -- This matches VSCode's behavior of only highlighting conflicting changes
  for _, change in ipairs(conflict_left_changes) do
    local range = change.modified
    if range and range.end_line > range.start_line then
      apply_line_highlights(left_bufnr, range, "CodeDiffLineInsert")
    end
    if change.inner_changes then
      for _, inner in ipairs(change.inner_changes) do
        local inner_range = inner.modified
        if inner_range and not is_empty_range(inner_range) then
          apply_char_highlight(left_bufnr, inner_range, "CodeDiffCharInsert", left_lines)
        end
      end
    end
  end

  for _, change in ipairs(conflict_right_changes) do
    local range = change.modified
    if range and range.end_line > range.start_line then
      apply_line_highlights(right_bufnr, range, "CodeDiffLineInsert")
    end
    if change.inner_changes then
      for _, inner in ipairs(change.inner_changes) do
        local inner_range = inner.modified
        if inner_range and not is_empty_range(inner_range) then
          apply_char_highlight(right_bufnr, inner_range, "CodeDiffCharInsert", right_lines)
        end
      end
    end
  end

  -- Extract fillers from alignments
  local left_fillers, right_fillers = alignments.left_fillers, alignments.right_fillers

  local total_left_fillers = 0
  local total_right_fillers = 0

  for _, filler in ipairs(left_fillers) do
    insert_filler_lines(left_bufnr, filler.after_line - 1, filler.count)
    total_left_fillers = total_left_fillers + filler.count
  end

  for _, filler in ipairs(right_fillers) do
    insert_filler_lines(right_bufnr, filler.after_line - 1, filler.count)
    total_right_fillers = total_right_fillers + filler.count
  end

  return {
    left_fillers = total_left_fillers,
    right_fillers = total_right_fillers,
    conflict_blocks = alignments.conflict_blocks,
  }
end

return M
