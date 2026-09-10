-- Compute conflict gutter markers from visual positions.
local M = {}

local function append_positions(positions, line, count)
  for offset = 1, count do
    positions[#positions + 1] = { line = line, offset = offset }
  end
end

--- Return the visual positions covered by one buffer-side range.
---
--- Ranges are one-based and half-open. Filler counts are indexed by the
--- one-based real-line anchor after which the filler is displayed. Anchor zero
--- represents filler above the first buffer line.
function M.visual_positions(range, filler_counts)
  if not range or range.start_line > range.end_line then
    return {}
  end

  filler_counts = filler_counts or {}
  local positions = {}

  if range.start_line == range.end_line then
    local anchor = range.start_line - 1
    local count = filler_counts[anchor] or 0
    if count == 0 then
      anchor = range.start_line
      count = filler_counts[anchor] or 0
    end
    append_positions(positions, anchor, count)
    return positions
  end

  append_positions(positions, range.start_line - 1, filler_counts[range.start_line - 1] or 0)
  for line = range.start_line, range.end_line - 1 do
    positions[#positions + 1] = { line = line, offset = 0 }
    append_positions(positions, line, filler_counts[line] or 0)
  end

  return positions
end

local function set_marker(markers, position, text)
  local line_markers = markers[position.line]
  if not line_markers then
    line_markers = {}
    markers[position.line] = line_markers
  end
  line_markers[position.offset] = text
end

--- Compute one marker for every supplied visual position.
function M.compute_markers(positions)
  local markers = {}
  local count = #positions

  for index, position in ipairs(positions) do
    local text
    if count == 1 then
      text = "["
    elseif index == 1 then
      text = "╭─"
    elseif index == count then
      text = "╰─"
    else
      text = "│ "
    end
    set_marker(markers, position, text)
  end

  return markers
end

return M
