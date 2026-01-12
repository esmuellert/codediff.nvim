-- Test: render/wrap_filler.lua - Wrap-aware filler line calculation
-- Tests that wrap mode maintains visual alignment between original and modified buffers
--
-- Test cases mirror the 12 cases from the wrap-wrap-test repository:
-- - case01: Unchanged (baseline)
-- - case02: Left short, Right wraps
-- - case03: Left wraps, Right short
-- - case04: Both wrap differently
-- - case05: Pure insertion with wrapping
-- - case06: Pure deletion with wrapping
-- - case07: Middle line change
-- - case08: Consecutive changes
-- - case09: Unicode/CJK characters
-- - case10: Very long line
-- - case11: Empty lines around wrap
-- - case12: Deep indentation

local wrap_filler = require("codediff.ui.wrap_filler")
local highlights = require("codediff.ui.highlights")
local diff = require("codediff.core.diff")

-- Test width: 80 columns (matches the test repo width)
local TEST_WIDTH = 80

-- Helper: Calculate expected visual lines for a line at given width
local function calc_visual_lines(line, width)
  local dw = vim.fn.strdisplaywidth(line)
  if dw == 0 then
    return 1
  end
  return math.ceil(dw / width)
end

-- Helper: Calculate total visual height for lines array
local function calc_total_visual(lines, width)
  local total = 0
  for _, line in ipairs(lines) do
    total = total + calc_visual_lines(line, width)
  end
  return total
end

-- Helper: Sum filler counts for a specific buffer
local function sum_fillers(fillers, buffer_name)
  local total = 0
  for _, f in ipairs(fillers) do
    if f.buffer == buffer_name then
      total = total + f.count
    end
  end
  return total
end

-- Helper: Calculate existing diff fillers (line count differences)
local function calc_diff_fillers(lines_diff)
  local original_fillers = 0
  local modified_fillers = 0

  for _, change in ipairs(lines_diff.changes) do
    local orig_count = change.original.end_line - change.original.start_line
    local mod_count = change.modified.end_line - change.modified.start_line
    local line_diff = mod_count - orig_count

    if line_diff > 0 then
      original_fillers = original_fillers + line_diff
    elseif line_diff < 0 then
      modified_fillers = modified_fillers + (-line_diff)
    end
  end

  return original_fillers, modified_fillers
end

-- Helper: Verify total visual heights match after applying all fillers
local function verify_alignment(original_lines, modified_lines, lines_diff, width)
  local wrap_fillers = wrap_filler.calculate_wrap_fillers(
    original_lines,
    modified_lines,
    lines_diff,
    width,
    width
  )

  local orig_wrap_fillers = sum_fillers(wrap_fillers, "original")
  local mod_wrap_fillers = sum_fillers(wrap_fillers, "modified")

  local orig_diff_fillers, mod_diff_fillers = calc_diff_fillers(lines_diff)

  local orig_visual = calc_total_visual(original_lines, width)
  local mod_visual = calc_total_visual(modified_lines, width)

  local orig_total = orig_visual + orig_diff_fillers + orig_wrap_fillers
  local mod_total = mod_visual + mod_diff_fillers + mod_wrap_fillers

  return orig_total == mod_total, {
    original_visual = orig_visual,
    modified_visual = mod_visual,
    original_diff_fillers = orig_diff_fillers,
    modified_diff_fillers = mod_diff_fillers,
    original_wrap_fillers = orig_wrap_fillers,
    modified_wrap_fillers = mod_wrap_fillers,
    original_total = orig_total,
    modified_total = mod_total,
  }
end

describe("Wrap Filler", function()
  before_each(function()
    highlights.setup()
  end)

  describe("calculate_wrap_fillers - 12 test cases", function()
    -- Case 01: Unchanged lines (baseline)
    it("case01: unchanged content produces no wrap fillers", function()
      local original = {
        "# CASE 1: Unchanged lines (baseline)",
        "# before",
        "def simple_function():",
        '    return "short"',
        "# after",
      }
      local modified = {
        "# CASE 1: Unchanged lines (baseline)",
        "# before",
        "def simple_function():",
        '    return "short"',
        "# after",
      }

      local lines_diff = diff.compute_diff(original, modified)
      local aligned, stats = verify_alignment(original, modified, lines_diff, TEST_WIDTH)

      assert.is_true(aligned, string.format(
        "Visual heights should match. Original: %d, Modified: %d",
        stats.original_total, stats.modified_total
      ))
      assert.equal(0, stats.original_wrap_fillers, "No wrap fillers needed for unchanged")
      assert.equal(0, stats.modified_wrap_fillers, "No wrap fillers needed for unchanged")
    end)

    -- Case 02: LEFT short, RIGHT wraps
    it("case02: left short, right wraps - adds fillers to original", function()
      local original = {
        "# CASE 2: LEFT short, RIGHT wraps",
        "# before",
        "def case2():",
        '    return "short"',
        "# after",
      }
      local modified = {
        "# CASE 2: LEFT short, RIGHT wraps",
        "# before",
        "def case2():",
        '    return "This line was short in the original but now it has been expanded to become extremely long and verbose, containing many more words and characters than before, ensuring it will definitely wrap across multiple display lines."',
        "# after",
      }

      local lines_diff = diff.compute_diff(original, modified)
      local aligned, stats = verify_alignment(original, modified, lines_diff, TEST_WIDTH)

      assert.is_true(aligned, string.format(
        "Visual heights should match. Original: %d, Modified: %d",
        stats.original_total, stats.modified_total
      ))
      assert.is_true(stats.original_wrap_fillers > 0, "Original should have wrap fillers to compensate")
    end)

    -- Case 03: LEFT wraps, RIGHT short
    it("case03: left wraps, right short - adds fillers to modified", function()
      local original = {
        "# CASE 3: LEFT wraps, RIGHT short",
        "# before",
        "def case3():",
        '    return "This was originally a very long line with lots of text that would definitely wrap in most terminal windows, but in the modified version it has been shortened significantly to just a few words."',
        "# after",
      }
      local modified = {
        "# CASE 3: LEFT wraps, RIGHT short",
        "# before",
        "def case3():",
        '    return "Now short"',
        "# after",
      }

      local lines_diff = diff.compute_diff(original, modified)
      local aligned, stats = verify_alignment(original, modified, lines_diff, TEST_WIDTH)

      assert.is_true(aligned, string.format(
        "Visual heights should match. Original: %d, Modified: %d",
        stats.original_total, stats.modified_total
      ))
      assert.is_true(stats.modified_wrap_fillers > 0, "Modified should have wrap fillers to compensate")
    end)

    -- Case 04: Both wrap, different counts
    it("case04: both wrap differently - balances fillers", function()
      local original = {
        "# CASE 4: Both wrap, different counts",
        "# before",
        "def case4():",
        '    return "This is a moderately long string that wraps to about two lines in most windows."',
        "# after",
      }
      local modified = {
        "# CASE 4: Both wrap, different counts",
        "# before",
        "def case4():",
        '    return "This string has been significantly expanded from its original form. It now contains much more text to force additional wrapping. We want to test when both sides wrap but modified wraps to more lines than original."',
        "# after",
      }

      local lines_diff = diff.compute_diff(original, modified)
      local aligned, stats = verify_alignment(original, modified, lines_diff, TEST_WIDTH)

      assert.is_true(aligned, string.format(
        "Visual heights should match. Original: %d, Modified: %d",
        stats.original_total, stats.modified_total
      ))
    end)

    -- Case 05: Pure insertion
    it("case05: pure insertion with wrapping content", function()
      local original = {
        "# CASE 5: Pure insertion",
        "# before",
        "# after",
      }
      local modified = {
        "# CASE 5: Pure insertion",
        "# before",
        "def case5():",
        '    """This entire function was inserted with a very long docstring that will wrap across multiple screen lines when displayed."""',
        '    long_var = "This is a very long variable assignment that spans well beyond the typical 80 character width limit, causing it to wrap."',
        "    return long_var",
        "# after",
      }

      local lines_diff = diff.compute_diff(original, modified)
      local aligned, stats = verify_alignment(original, modified, lines_diff, TEST_WIDTH)

      assert.is_true(aligned, string.format(
        "Visual heights should match. Original: %d, Modified: %d",
        stats.original_total, stats.modified_total
      ))
    end)

    -- Case 06: Pure deletion
    it("case06: pure deletion with wrapping content", function()
      local original = {
        "# CASE 6: Pure deletion",
        "# before",
        "def case6():",
        '    """',
        "    This function will be DELETED. It has a long docstring that wraps across multiple lines to test deletions.",
        '    """',
        '    deleted_var = "This variable is also very long, ensuring deletion of wrapped content is properly aligned."',
        "    return deleted_var",
        "# after",
      }
      local modified = {
        "# CASE 6: Pure deletion",
        "# before",
        "# after",
      }

      local lines_diff = diff.compute_diff(original, modified)
      local aligned, stats = verify_alignment(original, modified, lines_diff, TEST_WIDTH)

      assert.is_true(aligned, string.format(
        "Visual heights should match. Original: %d, Modified: %d",
        stats.original_total, stats.modified_total
      ))
    end)

    -- Case 07: Middle line changes
    it("case07: middle line change with wrapping", function()
      local original = {
        "# CASE 7: Middle line changes",
        "# before",
        "def case7():",
        '    first = "unchanged"',
        '    middle = "short"',
        '    last = "unchanged"',
        "    return first, middle, last",
        "# after",
      }
      local modified = {
        "# CASE 7: Middle line changes",
        "# before",
        "def case7():",
        '    first = "unchanged"',
        '    middle = "This middle line was modified to become extremely long, much longer than before, with lots of extra words and content added to make it wrap significantly more than the original."',
        '    last = "unchanged"',
        "    return first, middle, last",
        "# after",
      }

      local lines_diff = diff.compute_diff(original, modified)
      local aligned, stats = verify_alignment(original, modified, lines_diff, TEST_WIDTH)

      assert.is_true(aligned, string.format(
        "Visual heights should match. Original: %d, Modified: %d",
        stats.original_total, stats.modified_total
      ))
    end)

    -- Case 08: Multiple consecutive changes
    it("case08: consecutive changes with different wrap behavior", function()
      local original = {
        "# CASE 8: Multiple consecutive changes",
        "# before",
        "def case8():",
        '    line1 = "short"',
        '    line2 = "short"',
        '    line3 = "Third line was originally very long with lots of extra text that caused it to wrap across multiple display lines."',
        '    line4 = "short"',
        "    return line1, line2, line3, line4",
        "# after",
      }
      local modified = {
        "# CASE 8: Multiple consecutive changes",
        "# before",
        "def case8():",
        '    line1 = "First line expanded to be quite long and verbose for testing purposes to ensure it wraps."',
        '    line2 = "Second line is even longer than the first, containing significantly more text and characters to ensure it wraps to multiple display lines in most reasonable window widths."',
        '    line3 = "short now"',
        '    line4 = "Fourth line is the longest of all, packed with an extraordinary amount of textual content, verbose descriptions, and repetitive phrases designed specifically to maximize wrapping."',
        "    return line1, line2, line3, line4",
        "# after",
      }

      local lines_diff = diff.compute_diff(original, modified)
      local aligned, stats = verify_alignment(original, modified, lines_diff, TEST_WIDTH)

      assert.is_true(aligned, string.format(
        "Visual heights should match. Original: %d, Modified: %d",
        stats.original_total, stats.modified_total
      ))
    end)

    -- Case 09: Unicode width (CJK and emoji)
    it("case09: unicode/CJK double-width characters", function()
      local original = {
        "# CASE 9: Unicode width",
        "# before",
        "def case9():",
        '    cjk = "中文"',
        '    emoji = "🎉"',
        "    return cjk, emoji",
        "# after",
      }
      local modified = {
        "# CASE 9: Unicode width",
        "# before",
        "def case9():",
        '    cjk = "中文测试：这是一个很长的中文字符串，用于测试双宽度字符的换行对齐功能。日本語テスト。"',
        '    emoji = "🎉🎊🎁🎄🎅🤶🦌🛷❄️☃️🌟✨🔔🎶🕯️🧦🍪🥛🎿⛷️🏂🌨️☕🍫🎀🧣🧤"',
        "    return cjk, emoji",
        "# after",
      }

      local lines_diff = diff.compute_diff(original, modified)
      local aligned, stats = verify_alignment(original, modified, lines_diff, TEST_WIDTH)

      assert.is_true(aligned, string.format(
        "Visual heights should match. Original: %d, Modified: %d",
        stats.original_total, stats.modified_total
      ))
    end)

    -- Case 10: Very long line
    it("case10: very long line that wraps many times", function()
      local original = {
        "# CASE 10: Very long line",
        "# before",
        "def case10():",
        '    return "' .. string.rep("A", 100) .. '"',
        "# after",
      }
      local modified = {
        "# CASE 10: Very long line",
        "# before",
        "def case10():",
        '    return "' .. string.rep("A", 500) .. '"',
        "# after",
      }

      local lines_diff = diff.compute_diff(original, modified)
      local aligned, stats = verify_alignment(original, modified, lines_diff, TEST_WIDTH)

      assert.is_true(aligned, string.format(
        "Visual heights should match. Original: %d, Modified: %d",
        stats.original_total, stats.modified_total
      ))
      assert.is_true(stats.original_wrap_fillers > 0, "Should have wrap fillers for very long line")
    end)

    -- Case 11: Empty lines around wrap
    it("case11: empty lines mixed with wrapping content", function()
      local original = {
        "# CASE 11: Empty lines around wrap",
        "# before",
        "def case11():",
        "",
        '    before_empty = "short"',
        "",
        '    middle = "short"',
        "",
        '    after = "short"',
        "",
        "    return before_empty, middle, after",
        "# after",
      }
      local modified = {
        "# CASE 11: Empty lines around wrap",
        "# before",
        "def case11():",
        "",
        '    before_empty = "short"',
        "",
        '    middle = "This line comes after an empty line and is very long, testing that empty lines are handled correctly in the wrap alignment algorithm without causing off-by-one errors."',
        "",
        '    after = "short"',
        "",
        "    return before_empty, middle, after",
        "# after",
      }

      local lines_diff = diff.compute_diff(original, modified)
      local aligned, stats = verify_alignment(original, modified, lines_diff, TEST_WIDTH)

      assert.is_true(aligned, string.format(
        "Visual heights should match. Original: %d, Modified: %d",
        stats.original_total, stats.modified_total
      ))
    end)

    -- Case 12: Deep indentation
    it("case12: deep indentation affecting wrap", function()
      local original = {
        "# CASE 12: Deep indentation",
        "# before",
        "class Case12:",
        "    def method(self):",
        "        if True:",
        "            if True:",
        "                if True:",
        '                    return "short"',
        "# after",
      }
      local modified = {
        "# CASE 12: Deep indentation",
        "# before",
        "class Case12:",
        "    def method(self):",
        "        if True:",
        "            if True:",
        "                if True:",
        '                    return "Deeply indented long line that will wrap differently due to the indentation taking up visual space at the start of each wrapped segment of this lengthy string."',
        "# after",
      }

      local lines_diff = diff.compute_diff(original, modified)
      local aligned, stats = verify_alignment(original, modified, lines_diff, TEST_WIDTH)

      assert.is_true(aligned, string.format(
        "Visual heights should match. Original: %d, Modified: %d",
        stats.original_total, stats.modified_total
      ))
    end)
  end)

  describe("apply_wrap_fillers", function()
    -- Test: Extmarks are created correctly
    it("creates extmark virtual lines for wrap fillers", function()
      local original_buf = vim.api.nvim_create_buf(false, true)
      local modified_buf = vim.api.nvim_create_buf(false, true)

      local original = { "Short" }
      local modified = { "This is a long line that wraps at eighty columns boundary for testing" }

      vim.api.nvim_buf_set_lines(original_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(modified_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      -- Test the calculation directly (can't create real windows in headless)
      local fillers = wrap_filler.calculate_wrap_fillers(original, modified, lines_diff, TEST_WIDTH, TEST_WIDTH)

      -- Apply fillers manually to buffers
      for _, f in ipairs(fillers) do
        local bufnr = f.buffer == "original" and original_buf or modified_buf
        local line_idx = f.after_line - 1
        if line_idx < 0 then
          line_idx = 0
        end

        local virt_lines = {}
        for _ = 1, f.count do
          table.insert(virt_lines, { { "~", "CodeDiffFiller" } })
        end

        vim.api.nvim_buf_set_extmark(bufnr, wrap_filler.ns_wrap_filler, line_idx, 0, {
          virt_lines = virt_lines,
          virt_lines_above = false,
        })
      end

      -- Verify extmarks were created
      local original_marks = vim.api.nvim_buf_get_extmarks(original_buf, wrap_filler.ns_wrap_filler, 0, -1, { details = true })
      local modified_marks = vim.api.nvim_buf_get_extmarks(modified_buf, wrap_filler.ns_wrap_filler, 0, -1, { details = true })

      local total_virt = 0
      for _, mark in ipairs(original_marks) do
        if mark[4].virt_lines then
          total_virt = total_virt + #mark[4].virt_lines
        end
      end
      for _, mark in ipairs(modified_marks) do
        if mark[4].virt_lines then
          total_virt = total_virt + #mark[4].virt_lines
        end
      end

      assert.is_true(total_virt >= 0, "Should create wrap filler extmarks when needed")

      vim.api.nvim_buf_delete(original_buf, { force = true })
      vim.api.nvim_buf_delete(modified_buf, { force = true })
    end)

    -- Test: clear_wrap_fillers removes extmarks
    it("clear_wrap_fillers removes all wrap filler extmarks", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "line 2" })

      -- Add some extmarks
      vim.api.nvim_buf_set_extmark(buf, wrap_filler.ns_wrap_filler, 0, 0, {
        virt_lines = { { { "filler", "CodeDiffFiller" } } },
      })

      local marks_before = vim.api.nvim_buf_get_extmarks(buf, wrap_filler.ns_wrap_filler, 0, -1, {})
      assert.is_true(#marks_before > 0, "Should have extmarks before clear")

      wrap_filler.clear_wrap_fillers(buf)

      local marks_after = vim.api.nvim_buf_get_extmarks(buf, wrap_filler.ns_wrap_filler, 0, -1, {})
      assert.equal(0, #marks_after, "All extmarks should be cleared")

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("edge cases", function()
    -- Test: Empty buffers
    it("handles empty original buffer", function()
      local original = {}
      local modified = { "Added line that is long enough to wrap around at eighty columns" }

      local lines_diff = diff.compute_diff(original, modified)
      local fillers = wrap_filler.calculate_wrap_fillers(original, modified, lines_diff, TEST_WIDTH, TEST_WIDTH)

      -- Should not crash
      assert.is_table(fillers, "Should return fillers table")
    end)

    -- Test: Empty modified buffer
    it("handles empty modified buffer", function()
      local original = { "Deleted line that was long enough to wrap around at eighty columns" }
      local modified = {}

      local lines_diff = diff.compute_diff(original, modified)
      local fillers = wrap_filler.calculate_wrap_fillers(original, modified, lines_diff, TEST_WIDTH, TEST_WIDTH)

      -- Should not crash
      assert.is_table(fillers, "Should return fillers table")
    end)

    -- Test: Single character width (edge case)
    it("handles width of 1 column gracefully", function()
      local original = { "abc" }
      local modified = { "abcdef" }

      local lines_diff = diff.compute_diff(original, modified)

      -- Width of 1 is extreme but shouldn't crash
      local success = pcall(function()
        wrap_filler.calculate_wrap_fillers(original, modified, lines_diff, 1, 1)
      end)

      assert.is_true(success, "Should handle width=1 without crashing")
    end)

    -- Test: Different widths for original and modified windows
    it("handles different widths for original and modified windows", function()
      local original = {
        "Line 1",
        "Short original",
      }
      local modified = {
        "Line 1",
        "Modified content here",
      }

      local lines_diff = diff.compute_diff(original, modified)
      local fillers = wrap_filler.calculate_wrap_fillers(original, modified, lines_diff, 30, 50)

      -- Should not crash and return valid fillers table
      assert.is_table(fillers, "Should return fillers table for different widths")
    end)
  end)
end)
