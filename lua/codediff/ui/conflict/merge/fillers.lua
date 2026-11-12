-- Computes input-pane fillers and conflict regions.
local M = {}

local alignment = require("codediff.ui.conflict.merge.alignment")
local compute_mapping_alignments = alignment.compute_mapping_alignments
local get_alignments = alignment.get_alignments

function M.compute_merge_fillers(base_to_input1_diff, base_to_input2_diff, base_lines, input1_lines, input2_lines)
  -- Use VSCode's MappingAlignment.compute approach
  local mapping_alignments = compute_mapping_alignments(base_to_input1_diff.changes, base_to_input2_diff.changes)

  local all_left_fillers = {}
  local all_right_fillers = {}
  local left_total = 0
  local right_total = 0

  for _, ma in ipairs(mapping_alignments) do
    -- Get line alignments using VSCode's getAlignments
    local alignments = get_alignments(
      ma.base_range.start_line,
      ma.base_range.end_line,
      ma.output1_range.start_line,
      ma.output1_range.end_line,
      ma.output2_range.start_line,
      ma.output2_range.end_line,
      ma.inner1,
      ma.inner2
    )

    -- Convert alignments to fillers
    for _, a in ipairs(alignments) do
      if a.input1_line and a.input2_line then
        local left_adj = a.input1_line + left_total
        local right_adj = a.input2_line + right_total
        local mx = math.max(left_adj, right_adj)

        if mx - left_adj > 0 then
          table.insert(all_left_fillers, { after_line = a.input1_line - 1, count = mx - left_adj })
          left_total = left_total + (mx - left_adj)
        end
        if mx - right_adj > 0 then
          table.insert(all_right_fillers, { after_line = a.input2_line - 1, count = mx - right_adj })
          right_total = right_total + (mx - right_adj)
        end
      end
    end
  end

  return all_left_fillers, all_right_fillers
end

-- Compute fillers AND identify which changes are in conflict regions
-- A conflict region is where BOTH input1 and input2 have changes to the same base region
-- This matches VSCode's behavior of only highlighting conflicting changes
-- @param include_base boolean?: also align a visible Base pane, adding `base_fillers`
--   to the result and padding the inputs where Base is taller.
function M.compute_merge_fillers_and_conflicts(base_to_input1_diff, base_to_input2_diff, base_lines, input1_lines, input2_lines, include_base)
  -- Use VSCode's MappingAlignment.compute approach
  local mapping_alignments = compute_mapping_alignments(base_to_input1_diff.changes, base_to_input2_diff.changes)

  local all_left_fillers = {}
  local all_right_fillers = {}
  local all_base_fillers = {}
  local left_total = 0
  local right_total = 0
  local base_total = 0

  -- Track which changes are in conflict regions
  local conflict_left_changes = {}
  local conflict_right_changes = {}

  -- Track conflict blocks (for accept/reject actions)
  local conflict_blocks = {}

  for _, ma in ipairs(mapping_alignments) do
    -- A region is conflicting if BOTH sides have changes (inner1 and inner2 both non-empty)
    -- OR if both sides have changes (checked by looking at if the ranges differ from base)
    local has_left_changes = #ma.inner1 > 0 or (ma.output1_range.end_line - ma.output1_range.start_line) ~= (ma.base_range.end_line - ma.base_range.start_line)
    local has_right_changes = #ma.inner2 > 0 or (ma.output2_range.end_line - ma.output2_range.start_line) ~= (ma.base_range.end_line - ma.base_range.start_line)
    local is_conflict = has_left_changes and has_right_changes

    if is_conflict then
      -- Add to conflict blocks for action handling
      table.insert(conflict_blocks, ma)

      -- Collect the actual diff changes that fall within this alignment's base range
      for _, change in ipairs(base_to_input1_diff.changes or {}) do
        if change.original.start_line >= ma.base_range.start_line and change.original.end_line <= ma.base_range.end_line then
          table.insert(conflict_left_changes, change)
        end
      end
      for _, change in ipairs(base_to_input2_diff.changes or {}) do
        if change.original.start_line >= ma.base_range.start_line and change.original.end_line <= ma.base_range.end_line then
          table.insert(conflict_right_changes, change)
        end
      end
    end

    -- Get line alignments using VSCode's getAlignments
    local alignments = get_alignments(
      ma.base_range.start_line,
      ma.base_range.end_line,
      ma.output1_range.start_line,
      ma.output1_range.end_line,
      ma.output2_range.start_line,
      ma.output2_range.end_line,
      ma.inner1,
      ma.inner2
    )

    -- Convert alignments to fillers
    for _, a in ipairs(alignments) do
      if a.input1_line and a.input2_line then
        local left_adj = a.input1_line + left_total
        local right_adj = a.input2_line + right_total
        local base_adj = include_base and a.base_line and (a.base_line + base_total)
        local mx = math.max(left_adj, right_adj)

        if base_adj then
          mx = math.max(mx, base_adj)
        end

        if mx - left_adj > 0 then
          table.insert(all_left_fillers, { after_line = a.input1_line - 1, count = mx - left_adj })
          left_total = left_total + (mx - left_adj)
        end
        if mx - right_adj > 0 then
          table.insert(all_right_fillers, { after_line = a.input2_line - 1, count = mx - right_adj })
          right_total = right_total + (mx - right_adj)
        end
        if base_adj and mx - base_adj > 0 then
          table.insert(all_base_fillers, { after_line = a.base_line - 1, count = mx - base_adj })
          base_total = base_total + (mx - base_adj)
        end
      end
    end
  end

  return {
    left_fillers = all_left_fillers,
    right_fillers = all_right_fillers,
    base_fillers = include_base and all_base_fillers or nil,
    conflict_blocks = conflict_blocks,
  },
    conflict_left_changes,
    conflict_right_changes
end

return M
