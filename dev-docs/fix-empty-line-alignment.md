# Fix: Filler Line Calculation for Insertions at Empty Lines

## Issue
When new lines were inserted at empty line positions, filler lines were not being calculated, causing misalignment in the diff view. This was reported as "Wrong alignment of new line compared to gitsigns".

## Root Cause
In `lua/codediff/ui/core.lua`, the `calculate_fillers()` function has logic to handle character-level changes (inner_changes). For each inner change, it emits alignments at the end position:

```lua
local orig_line_len = original_lines[inner.original.end_line] and #original_lines[inner.original.end_line] or 0
if inner.original.end_col <= orig_line_len then
  emit_alignment(inner.original.end_line, inner.modified.end_line)
end
```

The problem: when the original line is empty (length=0) and the insertion happens at column 1 (end_col=1), the condition `1 <= 0` fails, preventing the alignment from being emitted. Without the alignment, no filler lines are calculated.

## The Fix
Changed the condition to allow for the valid insertion point one past the end of a line:

```lua
if inner.original.end_col <= orig_line_len + 1 then
  emit_alignment(inner.original.end_line, inner.modified.end_line)
end
```

This allows `end_col=1` to pass the check even when `orig_line_len=0`, which is correct because column 1 is a valid insertion point at the end of an empty line.

## Test Case
Added a regression test in `tests/render/core_spec.lua`:

```lua
it("Inserts filler lines for insertions at empty line positions", function()
  local original = {"line 1", "line 2", "", "line 4"}
  local modified = {"line 1", "line 2", "", "NEW line 3", "NEW line 4", "NEW line 5", "", "line 4"}
  -- ... test that filler extmarks are created
end)
```

## Validation
- All 174 existing tests pass
- New regression test validates the fix
- Filler lines are now correctly inserted for insertions at empty line positions
- The diff view maintains proper alignment

## Technical Details
- Filler lines are implemented as virtual lines using Neovim extmarks
- They are inserted with `virt_lines` option in the `ns_filler` namespace
- The fix ensures the alignment algorithm correctly handles edge cases with empty lines
- This matches the behavior of VSCode's diff algorithm (which this plugin is based on)
