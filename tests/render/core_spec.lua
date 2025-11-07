-- Test: render/core.lua - Core diff rendering logic
-- Critical tests for the heart of diff visualization

local core = require("vscode-diff.render.core")
local highlights = require("vscode-diff.render.highlights")
local diff = require("vscode-diff.diff")

describe("Render Core", function()
  before_each(function()
    highlights.setup()
  end)

  -- Test 1: Basic added lines rendering
  it("Renders added lines with correct highlights", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    local original = {"line 1", "line 2"}
    local modified = {"line 1", "line 2", "line 3"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    core.render_diff(left_buf, right_buf, original, modified, lines_diff)

    -- Verify added line has highlight
    local right_marks = vim.api.nvim_buf_get_extmarks(right_buf, highlights.ns_highlight, 0, -1, {})
    assert.is_true(#right_marks > 0, "Added line should have highlight extmark")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 2: Basic deleted lines rendering
  it("Renders deleted lines with correct highlights", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    local original = {"line 1", "line 2", "line 3"}
    local modified = {"line 1", "line 2"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    core.render_diff(left_buf, right_buf, original, modified, lines_diff)

    -- Verify deleted line has highlight
    local left_marks = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_highlight, 0, -1, {})
    assert.is_true(#left_marks > 0, "Deleted line should have highlight extmark")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 3: Basic modified lines rendering
  it("Renders modified lines with correct highlights", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    local original = {"line 1", "old content", "line 3"}
    local modified = {"line 1", "new content", "line 3"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    core.render_diff(left_buf, right_buf, original, modified, lines_diff)

    -- Both sides should have highlights for modified line
    local left_marks = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_highlight, 0, -1, {})
    local right_marks = vim.api.nvim_buf_get_extmarks(right_buf, highlights.ns_highlight, 0, -1, {})
    
    assert.is_true(#left_marks > 0, "Left buffer should have highlight for modified line")
    assert.is_true(#right_marks > 0, "Right buffer should have highlight for modified line")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 4: Filler lines inserted for alignment
  it("Inserts filler lines to maintain alignment", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    local original = {"line 1"}
    local modified = {"line 1", "added 1", "added 2", "added 3"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    core.render_diff(left_buf, right_buf, original, modified, lines_diff)

    -- Left buffer should have filler extmarks to align with right
    local left_fillers = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_filler, 0, -1, {})
    assert.is_true(#left_fillers > 0, "Left buffer should have filler lines")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 5: Character-level diff highlights
  it("Renders character-level differences within modified lines", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    local original = {"The quick brown fox"}
    local modified = {"The quick red fox"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    core.render_diff(left_buf, right_buf, original, modified, lines_diff)

    -- Should have character-level highlights
    local left_marks = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_highlight, 0, -1, {details = true})
    local right_marks = vim.api.nvim_buf_get_extmarks(right_buf, highlights.ns_highlight, 0, -1, {details = true})

    -- Check that we have highlights (character diffs create multiple extmarks)
    assert.is_true(#left_marks > 0, "Left should have character-level highlights")
    assert.is_true(#right_marks > 0, "Right should have character-level highlights")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 6: Empty diff (no changes)
  it("Handles empty diff with no changes gracefully", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    local lines = {"line 1", "line 2", "line 3"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, lines)

    local lines_diff = diff.compute_diff(lines, lines)
    core.render_diff(left_buf, right_buf, lines, lines, lines_diff)

    -- Should have no highlights or fillers
    local left_marks = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_highlight, 0, -1, {})
    local right_marks = vim.api.nvim_buf_get_extmarks(right_buf, highlights.ns_highlight, 0, -1, {})
    local left_fillers = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_filler, 0, -1, {})
    local right_fillers = vim.api.nvim_buf_get_extmarks(right_buf, highlights.ns_filler, 0, -1, {})

    assert.equal(0, #left_marks, "No highlights in left buffer")
    assert.equal(0, #right_marks, "No highlights in right buffer")
    assert.equal(0, #left_fillers, "No fillers in left buffer")
    assert.equal(0, #right_fillers, "No fillers in right buffer")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 7: Multiple consecutive added lines
  it("Renders multiple consecutive added lines correctly", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    local original = {"line 1", "line 5"}
    local modified = {"line 1", "line 2", "line 3", "line 4", "line 5"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    core.render_diff(left_buf, right_buf, original, modified, lines_diff)

    -- Right should have highlights for added lines
    local right_marks = vim.api.nvim_buf_get_extmarks(right_buf, highlights.ns_highlight, 0, -1, {})
    assert.is_true(#right_marks >= 3, "Should have highlights for 3 added lines")

    -- Left should have fillers
    local left_fillers = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_filler, 0, -1, {})
    assert.is_true(#left_fillers > 0, "Left should have fillers for alignment")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 8: Multiple consecutive deleted lines
  it("Renders multiple consecutive deleted lines correctly", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    local original = {"line 1", "line 2", "line 3", "line 4", "line 5"}
    local modified = {"line 1", "line 5"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    core.render_diff(left_buf, right_buf, original, modified, lines_diff)

    -- Left should have highlights for deleted lines
    local left_marks = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_highlight, 0, -1, {})
    assert.is_true(#left_marks >= 3, "Should have highlights for 3 deleted lines")

    -- Right should have fillers
    local right_fillers = vim.api.nvim_buf_get_extmarks(right_buf, highlights.ns_filler, 0, -1, {})
    assert.is_true(#right_fillers > 0, "Right should have fillers for alignment")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 9: Mixed changes (add, delete, modify in one diff)
  it("Renders mixed changes correctly in one diff", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    local original = {"keep", "delete this", "modify me", "keep"}
    local modified = {"keep", "modified", "add this", "keep"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    core.render_diff(left_buf, right_buf, original, modified, lines_diff)

    -- Both buffers should have highlights
    local left_marks = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_highlight, 0, -1, {})
    local right_marks = vim.api.nvim_buf_get_extmarks(right_buf, highlights.ns_highlight, 0, -1, {})

    assert.is_true(#left_marks > 0, "Left should have highlights for changes")
    assert.is_true(#right_marks > 0, "Right should have highlights for changes")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 10: Re-render clears previous extmarks
  it("Re-rendering clears previous extmarks before applying new ones", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    local original_v1 = {"line 1", "line 2"}
    local modified_v1 = {"line 1", "line 2", "added"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original_v1)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified_v1)

    -- First render
    local lines_diff_v1 = diff.compute_diff(original_v1, modified_v1)
    core.render_diff(left_buf, right_buf, original_v1, modified_v1, lines_diff_v1)

    local marks_after_first = vim.api.nvim_buf_get_extmarks(right_buf, highlights.ns_highlight, 0, -1, {})
    local first_count = #marks_after_first

    -- Second render with different content
    local original_v2 = {"line 1"}
    local modified_v2 = {"line 1"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original_v2)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified_v2)

    local lines_diff_v2 = diff.compute_diff(original_v2, modified_v2)
    core.render_diff(left_buf, right_buf, original_v2, modified_v2, lines_diff_v2)

    local marks_after_second = vim.api.nvim_buf_get_extmarks(right_buf, highlights.ns_highlight, 0, -1, {})

    -- Second render should clear old marks (no changes = no marks)
    assert.equal(0, #marks_after_second, "Old extmarks should be cleared on re-render")
    assert.is_true(first_count > 0, "First render had extmarks")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 11: Large number of filler lines
  it("Handles large number of filler lines efficiently", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    local original = {"line 1"}
    local modified = {"line 1"}
    -- Add 50 lines to right side
    for i = 2, 51 do
      table.insert(modified, "added line " .. i)
    end

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    
    -- Should not crash or timeout
    local success = pcall(function()
      core.render_diff(left_buf, right_buf, original, modified, lines_diff)
    end)

    assert.is_true(success, "Should handle large filler counts without error")

    -- Verify fillers were created
    local left_fillers = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_filler, 0, -1, {})
    assert.is_true(#left_fillers > 0, "Should create filler extmarks")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 12: Change at beginning of file
  it("Renders changes at the very beginning of file", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    local original = {"old first line", "line 2", "line 3"}
    local modified = {"new first line", "line 2", "line 3"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    core.render_diff(left_buf, right_buf, original, modified, lines_diff)

    -- First line should have highlights
    local left_marks = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_highlight, {0, 0}, {0, -1}, {})
    local right_marks = vim.api.nvim_buf_get_extmarks(right_buf, highlights.ns_highlight, {0, 0}, {0, -1}, {})

    assert.is_true(#left_marks > 0, "First line in left should have highlight")
    assert.is_true(#right_marks > 0, "First line in right should have highlight")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 13: Change at end of file
  it("Renders changes at the very end of file", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    local original = {"line 1", "line 2", "old last line"}
    local modified = {"line 1", "line 2", "new last line"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    core.render_diff(left_buf, right_buf, original, modified, lines_diff)

    -- Last line should have highlights
    local left_marks = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_highlight, {2, 0}, {2, -1}, {})
    local right_marks = vim.api.nvim_buf_get_extmarks(right_buf, highlights.ns_highlight, {2, 0}, {2, -1}, {})

    assert.is_true(#left_marks > 0, "Last line in left should have highlight")
    assert.is_true(#right_marks > 0, "Last line in right should have highlight")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 14: Whitespace-only changes
  it("Renders whitespace-only changes correctly", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    local original = {"line1", "  indented", "line3"}
    local modified = {"line1", "    indented", "line3"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    core.render_diff(left_buf, right_buf, original, modified, lines_diff)

    -- Should detect whitespace changes
    local left_marks = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_highlight, 0, -1, {})
    local right_marks = vim.api.nvim_buf_get_extmarks(right_buf, highlights.ns_highlight, 0, -1, {})

    assert.is_true(#left_marks > 0, "Whitespace changes should create highlights in left")
    assert.is_true(#right_marks > 0, "Whitespace changes should create highlights in right")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 15: Empty file vs file with content
  it("Handles diff between empty file and file with content", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    local original = {}
    local modified = {"line 1", "line 2", "line 3"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    
    -- Should not crash with empty file
    local success = pcall(function()
      core.render_diff(left_buf, right_buf, original, modified, lines_diff)
    end)

    assert.is_true(success, "Should handle empty file vs content without error")

    -- Verify buffers are still valid after rendering
    assert.is_true(vim.api.nvim_buf_is_valid(left_buf), "Left buffer should remain valid")
    assert.is_true(vim.api.nvim_buf_is_valid(right_buf), "Right buffer should remain valid")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)
end)
