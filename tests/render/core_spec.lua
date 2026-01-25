-- Test: render/core.lua - Core diff rendering logic
-- Critical tests for the heart of diff visualization

local core = require("codediff.ui.core")
local highlights = require("codediff.ui.highlights")
local diff = require('codediff.core.diff')

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

  -- Test 16: render_single_buffer with modified side
  it("render_single_buffer renders modified side with insert highlights", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = {"line 1", "line 2"}
    local modified = {"line 1", "line 2", "line 3"}

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    core.render_single_buffer(buf, lines_diff, "modified")

    -- Verify added line has highlight
    local marks = vim.api.nvim_buf_get_extmarks(buf, highlights.ns_highlight, 0, -1, {})
    assert.is_true(#marks > 0, "Modified side should have highlight extmarks")

    vim.api.nvim_buf_delete(buf, {force = true})
  end)

  -- Test 17: render_single_buffer with original side
  it("render_single_buffer renders original side with delete highlights", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = {"line 1", "line 2", "line 3"}
    local modified = {"line 1", "line 2"}

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)

    local lines_diff = diff.compute_diff(original, modified)
    core.render_single_buffer(buf, lines_diff, "original")

    -- Verify deleted line has highlight
    local marks = vim.api.nvim_buf_get_extmarks(buf, highlights.ns_highlight, 0, -1, {})
    assert.is_true(#marks > 0, "Original side should have highlight extmarks")

    vim.api.nvim_buf_delete(buf, {force = true})
  end)

  -- Test 18: render_single_buffer clears previous highlights
  it("render_single_buffer clears previous highlights on re-render", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original_v1 = {"line 1"}
    local modified_v1 = {"line 1", "added"}

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified_v1)

    -- First render
    local lines_diff_v1 = diff.compute_diff(original_v1, modified_v1)
    core.render_single_buffer(buf, lines_diff_v1, "modified")

    local marks_after_first = vim.api.nvim_buf_get_extmarks(buf, highlights.ns_highlight, 0, -1, {})
    local first_count = #marks_after_first

    -- Second render with no changes
    local no_change = {"same"}
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, no_change)
    local lines_diff_v2 = diff.compute_diff(no_change, no_change)
    core.render_single_buffer(buf, lines_diff_v2, "modified")

    local marks_after_second = vim.api.nvim_buf_get_extmarks(buf, highlights.ns_highlight, 0, -1, {})

    assert.is_true(first_count > 0, "First render had extmarks")
    assert.equal(0, #marks_after_second, "Old extmarks should be cleared on re-render")

    vim.api.nvim_buf_delete(buf, {force = true})
  end)

  -- Test 19: render_single_buffer with no changes
  it("render_single_buffer handles no changes gracefully", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local content = {"line 1", "line 2"}
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)

    local lines_diff = diff.compute_diff(content, content)
    
    local success = pcall(function()
      core.render_single_buffer(buf, lines_diff, "modified")
    end)

    assert.is_true(success, "Should handle no changes without error")

    local marks = vim.api.nvim_buf_get_extmarks(buf, highlights.ns_highlight, 0, -1, {})
    assert.equal(0, #marks, "No changes should mean no highlights")

    vim.api.nvim_buf_delete(buf, {force = true})
  end)

  -- Test 20: Insertions at empty lines produce filler lines (regression test for issue)
  it("Inserts filler lines for insertions at empty line positions", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    -- Test case: insertion after an empty line
    -- This was the bug: empty lines (len=0) with end_col=1 failed the condition
    -- and prevented filler lines from being calculated
    local original = {"line 1", "line 2", "", "line 4"}
    local modified = {"line 1", "line 2", "", "NEW line 3", "NEW line 4", "NEW line 5", "", "line 4"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    core.render_diff(left_buf, right_buf, original, modified, lines_diff)

    -- Left buffer MUST have filler extmarks to align with the new lines in right
    local left_fillers = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_filler, 0, -1, {details = true})
    assert.is_true(#left_fillers > 0, "Left buffer must have filler lines for insertions at empty line")
    
    -- Verify the filler has the correct number of virtual lines
    local filler_found = false
    for _, mark in ipairs(left_fillers) do
      local details = mark[4]
      if details.virt_lines and #details.virt_lines > 0 then
        filler_found = true
        -- We inserted 3 new lines, so we need at least 3 filler lines
        assert.is_true(#details.virt_lines >= 3, "Filler should have at least 3 virtual lines")
      end
    end
    assert.is_true(filler_found, "Should have found filler with virt_lines")

    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)
end)
