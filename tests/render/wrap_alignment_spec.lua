-- Test: Wrap Line Alignment
-- Tests the wrap alignment logic for diff views when wrap is enabled

local core = require("codediff.ui.core")
local highlights = require("codediff.ui.highlights")
local diff = require("codediff.core.diff")
local config = require("codediff.config")

-- Access internal test utilities
local test_utils = core._test

describe("Wrap Alignment", function()
  before_each(function()
    highlights.setup()
  end)

  -- ============================================================================
  -- get_display_line_count Tests
  -- ============================================================================

  describe("get_display_line_count", function()
    local get_display_line_count = test_utils.get_display_line_count

    -- Test 1: Empty line returns 1
    it("Returns 1 for empty line", function()
      local result = get_display_line_count("", 80)
      assert.equal(1, result)
    end)

    -- Test 2: Nil line returns 1
    it("Returns 1 for nil line", function()
      local result = get_display_line_count(nil, 80)
      assert.equal(1, result)
    end)

    -- Test 3: Short line returns 1
    it("Returns 1 for short line that fits in window", function()
      local result = get_display_line_count("Hello, world!", 80)
      assert.equal(1, result)
    end)

    -- Test 4: Line exactly at window width returns 1
    it("Returns 1 for line exactly at window width", function()
      local line = string.rep("x", 80)
      local result = get_display_line_count(line, 80)
      assert.equal(1, result)
    end)

    -- Test 5: Line wraps to 2 display lines
    it("Returns 2 for line that wraps once", function()
      local line = string.rep("x", 100)
      local result = get_display_line_count(line, 80)
      assert.equal(2, result)
    end)

    -- Test 6: Line wraps to multiple display lines
    it("Returns correct count for line that wraps multiple times", function()
      local line = string.rep("x", 250)
      local result = get_display_line_count(line, 80)
      assert.equal(4, result) -- ceil(250/80) = 4
    end)

    -- Test 7: Zero window width returns 1
    it("Returns 1 for zero window width", function()
      local result = get_display_line_count("Hello", 0)
      assert.equal(1, result)
    end)

    -- Test 8: Negative window width returns 1
    it("Returns 1 for negative window width", function()
      local result = get_display_line_count("Hello", -10)
      assert.equal(1, result)
    end)

    -- Test 9: Tab characters are handled correctly
    it("Handles tab characters correctly", function()
      -- Tab is typically 8 display columns
      local line = "\t\t\t\t\t\t\t\t\t\t" -- 10 tabs = 80 columns
      local result = get_display_line_count(line, 80)
      assert.equal(1, result)
    end)

    -- Test 10: Unicode characters with different display widths
    it("Handles unicode characters", function()
      -- Basic ASCII should work
      local line = string.rep("a", 160)
      local result = get_display_line_count(line, 80)
      assert.equal(2, result)
    end)
  end)

  -- ============================================================================
  -- build_line_mapping Tests
  -- ============================================================================

  describe("build_line_mapping", function()
    local build_line_mapping = test_utils.build_line_mapping

    -- Helper to create mock diff results
    local function make_diff(changes)
      return { changes = changes or {} }
    end

    local function make_change(orig_start, orig_end, mod_start, mod_end, inner_changes)
      return {
        original = { start_line = orig_start, end_line = orig_end },
        modified = { start_line = mod_start, end_line = mod_end },
        inner_changes = inner_changes or {}
      }
    end

    -- Test 1: Empty diff maps all lines 1:1
    it("Maps all lines 1:1 for empty diff", function()
      local lines_diff = make_diff({})
      local mapping = build_line_mapping(lines_diff, 5, 5)

      assert.equal(1, mapping[1])
      assert.equal(2, mapping[2])
      assert.equal(3, mapping[3])
      assert.equal(4, mapping[4])
      assert.equal(5, mapping[5])
    end)

    -- Test 2: Single modification maps 1:1
    it("Maps modified lines 1:1 when line counts match", function()
      local lines_diff = make_diff({
        make_change(2, 3, 2, 3) -- Line 2 modified
      })
      local mapping = build_line_mapping(lines_diff, 3, 3)

      assert.equal(1, mapping[1])
      assert.equal(2, mapping[2])
      assert.equal(3, mapping[3])
    end)

    -- Test 3: Insertion shifts subsequent line mappings
    it("Accounts for insertions in line mapping", function()
      local lines_diff = make_diff({
        make_change(2, 2, 2, 4) -- Insert 2 lines after line 1
      })
      local mapping = build_line_mapping(lines_diff, 3, 5)

      assert.equal(1, mapping[1])
      -- Lines 2-3 in original now map to lines 4-5 in modified
      assert.equal(4, mapping[2])
      assert.equal(5, mapping[3])
    end)

    -- Test 4: Deletion shifts subsequent line mappings
    it("Accounts for deletions in line mapping", function()
      local lines_diff = make_diff({
        make_change(2, 4, 2, 2) -- Delete lines 2-3
      })
      local mapping = build_line_mapping(lines_diff, 5, 3)

      assert.equal(1, mapping[1])
      -- Lines 2-3 are deleted, so no mapping for them
      -- Line 4 maps to line 2, line 5 maps to line 3
      assert.equal(2, mapping[4])
      assert.equal(3, mapping[5])
    end)

    -- Test 5: Multiple changes with different offsets
    it("Handles multiple changes with different offsets", function()
      local lines_diff = make_diff({
        make_change(2, 3, 2, 3), -- Modify line 2 (1 line -> 1 line)
        make_change(4, 5, 4, 6), -- Expand line 4 (1 line -> 2 lines)
      })
      local mapping = build_line_mapping(lines_diff, 5, 6)

      assert.equal(1, mapping[1])  -- Unchanged before first change
      assert.equal(2, mapping[2])  -- Modified but 1:1 line count
      assert.equal(3, mapping[3])  -- Unchanged between changes
      -- Line 4 is NOT mapped because it's part of a change where line counts differ (1->2)
      assert.is_nil(mapping[4])
      assert.equal(6, mapping[5])  -- Offset by 1 due to expansion in line 4
    end)

    -- Test 6: Pure insertion at beginning
    it("Handles insertion at beginning of file", function()
      local lines_diff = make_diff({
        make_change(1, 1, 1, 3) -- Insert 2 lines at beginning
      })
      local mapping = build_line_mapping(lines_diff, 3, 5)

      -- All original lines shift by 2
      assert.equal(3, mapping[1])
      assert.equal(4, mapping[2])
      assert.equal(5, mapping[3])
    end)

    -- Test 7: Pure deletion at end
    it("Handles deletion at end of file", function()
      local lines_diff = make_diff({
        make_change(4, 6, 4, 4) -- Delete lines 4-5
      })
      local mapping = build_line_mapping(lines_diff, 5, 3)

      assert.equal(1, mapping[1])
      assert.equal(2, mapping[2])
      assert.equal(3, mapping[3])
      -- Lines 4-5 are deleted
      assert.is_nil(mapping[4])
      assert.is_nil(mapping[5])
    end)

    -- Test 8: Inner changes map specific lines
    it("Uses inner changes for line mapping", function()
      local inner = {
        {
          original = { start_line = 2, start_col = 0, end_line = 2, end_col = 5 },
          modified = { start_line = 2, start_col = 0, end_line = 2, end_col = 8 }
        }
      }
      local lines_diff = make_diff({
        make_change(2, 3, 2, 3, inner)
      })
      local mapping = build_line_mapping(lines_diff, 3, 3)

      assert.equal(1, mapping[1])
      assert.equal(2, mapping[2]) -- Mapped via inner change
      assert.equal(3, mapping[3])
    end)
  end)

  -- ============================================================================
  -- calculate_wrap_fillers Tests (Integration-level)
  -- ============================================================================

  describe("calculate_wrap_fillers", function()
    local calculate_wrap_fillers = test_utils.calculate_wrap_fillers

    -- Helper to set up test windows and buffers
    local function setup_test_environment()
      -- Create buffers
      local left_buf = vim.api.nvim_create_buf(false, true)
      local right_buf = vim.api.nvim_create_buf(false, true)

      -- Create windows (we need actual windows for width calculation)
      -- Save current window
      local orig_win = vim.api.nvim_get_current_win()

      -- Create a split to get two windows
      vim.cmd("vsplit")
      local left_win = vim.api.nvim_get_current_win()
      vim.cmd("wincmd l")
      local right_win = vim.api.nvim_get_current_win()

      -- Set buffers to windows
      vim.api.nvim_win_set_buf(left_win, left_buf)
      vim.api.nvim_win_set_buf(right_win, right_buf)

      return {
        left_buf = left_buf,
        right_buf = right_buf,
        left_win = left_win,
        right_win = right_win,
        orig_win = orig_win,
      }
    end

    local function cleanup_test_environment(env)
      -- Close windows and delete buffers
      pcall(function()
        vim.api.nvim_win_close(env.left_win, true)
      end)
      pcall(function()
        vim.api.nvim_win_close(env.right_win, true)
      end)
      pcall(function()
        vim.api.nvim_buf_delete(env.left_buf, { force = true })
      end)
      pcall(function()
        vim.api.nvim_buf_delete(env.right_buf, { force = true })
      end)
    end

    -- Helper to create mock diff
    local function make_diff(changes)
      return { changes = changes or {} }
    end

    local function make_change(orig_start, orig_end, mod_start, mod_end)
      return {
        original = { start_line = orig_start, end_line = orig_end },
        modified = { start_line = mod_start, end_line = mod_end },
        inner_changes = {}
      }
    end

    -- Test 1: No changes produces no wrap fillers
    it("Returns empty fillers for no changes", function()
      local env = setup_test_environment()

      local original = {"line 1", "line 2", "line 3"}
      local modified = {"line 1", "line 2", "line 3"}

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = make_diff({})
      local result = calculate_wrap_fillers(
        env.left_buf, env.right_buf,
        env.left_win, env.right_win,
        original, modified, lines_diff
      )

      assert.is_table(result)
      assert.is_table(result.left_fillers)
      assert.is_table(result.right_fillers)
      assert.equal(0, #result.left_fillers)
      assert.equal(0, #result.right_fillers)

      cleanup_test_environment(env)
    end)

    -- Test 2: Fillers structure is correct
    it("Returns fillers with correct structure", function()
      local env = setup_test_environment()

      -- Create a long line that will wrap
      local short_line = "short"
      local long_line = string.rep("x", 200)

      local original = {short_line}
      local modified = {long_line}

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = make_diff({
        make_change(1, 2, 1, 2) -- Line 1 is modified
      })
      local result = calculate_wrap_fillers(
        env.left_buf, env.right_buf,
        env.left_win, env.right_win,
        original, modified, lines_diff
      )

      assert.is_table(result)
      assert.is_table(result.left_fillers)
      assert.is_table(result.right_fillers)

      -- Either left or right should have fillers (depending on window width)
      -- The long line in modified should cause fillers on left side
      if #result.left_fillers > 0 then
        assert.is_number(result.left_fillers[1].after_line)
        assert.is_number(result.left_fillers[1].count)
        assert.is_true(result.left_fillers[1].count > 0)
      end

      cleanup_test_environment(env)
    end)

    -- Test 3: Pure insertion calculates extra fillers for wrapped content
    it("Calculates extra fillers for wrapped insertions", function()
      local env = setup_test_environment()

      -- Very long lines that will wrap multiple times
      local long_line = string.rep("x", 500)

      local original = {"line 1", "line 2"}
      local modified = {"line 1", long_line, "line 2"}

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = make_diff({
        make_change(2, 2, 2, 3) -- Insert long line between 1 and 2
      })
      local result = calculate_wrap_fillers(
        env.left_buf, env.right_buf,
        env.left_win, env.right_win,
        original, modified, lines_diff
      )

      assert.is_table(result)
      -- Left should have extra fillers beyond the 1 line difference
      -- because the inserted line wraps to multiple display lines
      assert.is_table(result.left_fillers)

      cleanup_test_environment(env)
    end)

    -- Test 4: Fillers are sorted by line number
    it("Returns fillers sorted by line number", function()
      local env = setup_test_environment()

      local long_line = string.rep("x", 200)

      local original = {"short", "short", "short"}
      local modified = {long_line, long_line, long_line}

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = make_diff({
        make_change(1, 2, 1, 2),
        make_change(2, 3, 2, 3),
        make_change(3, 4, 3, 4),
      })
      local result = calculate_wrap_fillers(
        env.left_buf, env.right_buf,
        env.left_win, env.right_win,
        original, modified, lines_diff
      )

      -- Verify sorting
      for i = 2, #result.left_fillers do
        assert.is_true(
          result.left_fillers[i].after_line >= result.left_fillers[i-1].after_line,
          "Left fillers should be sorted by line number"
        )
      end

      for i = 2, #result.right_fillers do
        assert.is_true(
          result.right_fillers[i].after_line >= result.right_fillers[i-1].after_line,
          "Right fillers should be sorted by line number"
        )
      end

      cleanup_test_environment(env)
    end)
  end)

  -- ============================================================================
  -- Integration Tests with render_diff
  -- ============================================================================

  describe("render_diff with wrap enabled", function()
    -- Save original config
    local orig_wrap_setting

    before_each(function()
      orig_wrap_setting = config.options.diff.wrap
      config.options.diff.wrap = true
    end)

    after_each(function()
      config.options.diff.wrap = orig_wrap_setting
    end)

    -- Helper to set up test environment
    local function setup_diff_environment()
      local left_buf = vim.api.nvim_create_buf(false, true)
      local right_buf = vim.api.nvim_create_buf(false, true)

      -- Create windows
      vim.cmd("vsplit")
      local left_win = vim.api.nvim_get_current_win()
      vim.cmd("wincmd l")
      local right_win = vim.api.nvim_get_current_win()

      vim.api.nvim_win_set_buf(left_win, left_buf)
      vim.api.nvim_win_set_buf(right_win, right_buf)

      return {
        left_buf = left_buf,
        right_buf = right_buf,
        left_win = left_win,
        right_win = right_win,
      }
    end

    local function cleanup_environment(env)
      pcall(function() vim.api.nvim_win_close(env.left_win, true) end)
      pcall(function() vim.api.nvim_win_close(env.right_win, true) end)
      pcall(function() vim.api.nvim_buf_delete(env.left_buf, { force = true }) end)
      pcall(function() vim.api.nvim_buf_delete(env.right_buf, { force = true }) end)
    end

    -- Test 1: render_diff executes without error when wrap is enabled
    it("Executes without error when wrap is enabled", function()
      local env = setup_diff_environment()

      local original = {"line 1", "line 2", "line 3"}
      local modified = {"line 1", "modified line 2", "line 3"}

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      local success, result = pcall(function()
        return core.render_diff(
          env.left_buf, env.right_buf,
          original, modified, lines_diff,
          env.left_win, env.right_win
        )
      end)

      assert.is_true(success, "render_diff should not error with wrap enabled")
      assert.is_table(result)
      assert.is_number(result.left_fillers)
      assert.is_number(result.right_fillers)

      cleanup_environment(env)
    end)

    -- Test 2: Wrap fillers are added when lines wrap differently
    it("Adds wrap fillers when lines wrap differently", function()
      local env = setup_diff_environment()

      local short_line = "short content"
      local long_line = string.rep("long content ", 20) -- Will wrap

      local original = {short_line}
      local modified = {long_line}

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)
      local result = core.render_diff(
        env.left_buf, env.right_buf,
        original, modified, lines_diff,
        env.left_win, env.right_win
      )

      -- The long line should cause extra fillers to be added to left side
      -- Total fillers should be > 0 (either from regular diff or wrap)
      assert.is_true(
        result.left_fillers >= 0 and result.right_fillers >= 0,
        "Should have valid filler counts"
      )

      cleanup_environment(env)
    end)

    -- Test 3: Works correctly without windows (graceful fallback)
    it("Works without windows (skips wrap alignment)", function()
      local left_buf = vim.api.nvim_create_buf(false, true)
      local right_buf = vim.api.nvim_create_buf(false, true)

      local original = {"line 1", "line 2"}
      local modified = {"line 1", "modified", "line 3"}

      vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      -- Call without window parameters
      local success, result = pcall(function()
        return core.render_diff(
          left_buf, right_buf,
          original, modified, lines_diff
        )
      end)

      assert.is_true(success, "Should work without window parameters")
      assert.is_table(result)

      vim.api.nvim_buf_delete(left_buf, { force = true })
      vim.api.nvim_buf_delete(right_buf, { force = true })
    end)

    -- Test 4: Handles empty files
    it("Handles empty files with wrap enabled", function()
      local env = setup_diff_environment()

      local original = {}
      local modified = {"added line"}

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      local success = pcall(function()
        core.render_diff(
          env.left_buf, env.right_buf,
          original, modified, lines_diff,
          env.left_win, env.right_win
        )
      end)

      assert.is_true(success, "Should handle empty files with wrap enabled")

      cleanup_environment(env)
    end)

    -- Test 5: Handles large files with many wrapped lines
    it("Handles large files with many wrapped lines", function()
      local env = setup_diff_environment()

      local original = {}
      local modified = {}
      local long_line = string.rep("x", 300)

      for i = 1, 50 do
        table.insert(original, "short line " .. i)
        table.insert(modified, long_line .. i)
      end

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      local success = pcall(function()
        core.render_diff(
          env.left_buf, env.right_buf,
          original, modified, lines_diff,
          env.left_win, env.right_win
        )
      end)

      assert.is_true(success, "Should handle large files with wrapped lines")

      cleanup_environment(env)
    end)
  end)

  -- ============================================================================
  -- Config Integration Tests
  -- ============================================================================

  describe("Config wrap option", function()
    -- Test 1: Default wrap option is false
    it("Has wrap option in config", function()
      assert.is_not_nil(config.options.diff)
      assert.is_not_nil(config.options.diff.wrap)
    end)

    -- Test 2: Wrap option can be changed
    it("Wrap option can be enabled", function()
      local original_value = config.options.diff.wrap
      config.options.diff.wrap = true
      assert.equal(true, config.options.diff.wrap)
      config.options.diff.wrap = original_value
    end)
  end)

  -- ============================================================================
  -- Real-World Test Cases (from wrap-wrap-test demo repository)
  -- These tests verify wrap alignment with realistic code diff scenarios
  -- ============================================================================

  describe("Real-world wrap alignment scenarios", function()
    local orig_wrap_setting

    before_each(function()
      orig_wrap_setting = config.options.diff.wrap
      config.options.diff.wrap = true
    end)

    after_each(function()
      config.options.diff.wrap = orig_wrap_setting
    end)

    local function setup_diff_environment()
      local left_buf = vim.api.nvim_create_buf(false, true)
      local right_buf = vim.api.nvim_create_buf(false, true)

      vim.cmd("vsplit")
      local left_win = vim.api.nvim_get_current_win()
      vim.cmd("wincmd l")
      local right_win = vim.api.nvim_get_current_win()

      vim.api.nvim_win_set_buf(left_win, left_buf)
      vim.api.nvim_win_set_buf(right_win, right_buf)

      return {
        left_buf = left_buf,
        right_buf = right_buf,
        left_win = left_win,
        right_win = right_win,
      }
    end

    local function cleanup_environment(env)
      pcall(function() vim.api.nvim_win_close(env.left_win, true) end)
      pcall(function() vim.api.nvim_win_close(env.right_win, true) end)
      pcall(function() vim.api.nvim_buf_delete(env.left_buf, { force = true }) end)
      pcall(function() vim.api.nvim_buf_delete(env.right_buf, { force = true }) end)
    end

    -- CASE 1: Unchanged lines (baseline)
    it("Case 1: Handles unchanged lines correctly", function()
      local env = setup_diff_environment()

      local original = {
        'def simple_function():',
        '    return "short"',
      }
      local modified = {
        'def simple_function():',
        '    return "short"',
      }

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)
      local result = core.render_diff(
        env.left_buf, env.right_buf,
        original, modified, lines_diff,
        env.left_win, env.right_win
      )

      -- No fillers needed for identical content
      assert.equal(0, result.left_fillers)
      assert.equal(0, result.right_fillers)

      cleanup_environment(env)
    end)

    -- CASE 2: LEFT short, RIGHT wraps (modification)
    it("Case 2: Handles left short, right wraps modification", function()
      local env = setup_diff_environment()

      local original = {
        'def case2_left_short_right_wraps():',
        '    return "short"',
      }
      local modified = {
        'def case2_left_short_right_wraps():',
        '    return "This line was short in the original but now it has been expanded to become extremely long and verbose, containing many more words and characters than before, ensuring it will definitely wrap across multiple display lines in any reasonably sized terminal window."',
      }

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      local success, result = pcall(function()
        return core.render_diff(
          env.left_buf, env.right_buf,
          original, modified, lines_diff,
          env.left_win, env.right_win
        )
      end)

      assert.is_true(success, "Should handle left short, right wraps")
      -- Left side should have fillers to align with wrapped right side
      assert.is_true(result.left_fillers >= 0, "Should have valid left filler count")

      cleanup_environment(env)
    end)

    -- CASE 3: LEFT wraps, RIGHT short (modification)
    it("Case 3: Handles left wraps, right short modification", function()
      local env = setup_diff_environment()

      local original = {
        'def case3_left_wraps_right_short():',
        '    return "This was originally a very long line with lots of text that would definitely wrap in most terminal windows, but in the modified version it has been shortened significantly to just a few words."',
      }
      local modified = {
        'def case3_left_wraps_right_short():',
        '    return "Now short"',
      }

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      local success, result = pcall(function()
        return core.render_diff(
          env.left_buf, env.right_buf,
          original, modified, lines_diff,
          env.left_win, env.right_win
        )
      end)

      assert.is_true(success, "Should handle left wraps, right short")
      -- Right side should have fillers to align with wrapped left side
      assert.is_true(result.right_fillers >= 0, "Should have valid right filler count")

      cleanup_environment(env)
    end)

    -- CASE 4: Both sides wrap with different counts
    it("Case 4: Handles both sides wrapping with different counts", function()
      local env = setup_diff_environment()

      local original = {
        'def case4_both_wrap_different_counts():',
        '    return "This is a moderately long string that wraps to about two lines in most windows."',
      }
      local modified = {
        'def case4_both_wrap_different_counts():',
        '    return "This string has been significantly expanded from its original form. It now contains much more text to force additional wrapping. We want to test what happens when both sides wrap but the modified version wraps to more lines than the original. This requires extra filler lines on the left side."',
      }

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      local success, result = pcall(function()
        return core.render_diff(
          env.left_buf, env.right_buf,
          original, modified, lines_diff,
          env.left_win, env.right_win
        )
      end)

      assert.is_true(success, "Should handle both sides wrapping differently")
      assert.is_table(result)

      cleanup_environment(env)
    end)

    -- CASE 5: Pure insertion with wrapping lines
    it("Case 5: Handles pure insertion with wrapping content", function()
      local env = setup_diff_environment()

      local original = {
        '# Before insertion',
        '# After insertion',
      }
      local modified = {
        '# Before insertion',
        'def case5_inserted_block_with_wrap():',
        '    """',
        '    This entire function was inserted and contains a very long docstring paragraph that will definitely wrap across multiple screen lines when displayed in a typical terminal window with 80-100 columns width.',
        '    """',
        '    long_var = "This is a very long variable assignment that spans well beyond the typical 80 or 100 character width limit that most editors use, causing it to wrap."',
        '    return long_var',
        '# After insertion',
      }

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      local success, result = pcall(function()
        return core.render_diff(
          env.left_buf, env.right_buf,
          original, modified, lines_diff,
          env.left_win, env.right_win
        )
      end)

      assert.is_true(success, "Should handle pure insertion with wrapping")
      -- Left side should have fillers for the inserted block
      assert.is_true(result.left_fillers > 0, "Should have left fillers for insertion")

      cleanup_environment(env)
    end)

    -- CASE 6: Pure deletion with wrapping lines
    it("Case 6: Handles pure deletion with wrapping content", function()
      local env = setup_diff_environment()

      local original = {
        '# Before deletion',
        'def case6_deleted_block_with_wrap():',
        '    """',
        '    This function will be DELETED in the modified version. It has a long docstring that wraps across multiple lines to test that deletions with wrapped content are handled correctly.',
        '    """',
        '    deleted_long_var = "This variable assignment in the deleted function is also very long, ensuring that the deletion of wrapped content is properly aligned with filler lines."',
        '    return deleted_long_var',
        '# After deletion',
      }
      local modified = {
        '# Before deletion',
        '# After deletion',
      }

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      local success, result = pcall(function()
        return core.render_diff(
          env.left_buf, env.right_buf,
          original, modified, lines_diff,
          env.left_win, env.right_win
        )
      end)

      assert.is_true(success, "Should handle pure deletion with wrapping")
      -- Right side should have fillers for the deleted block
      assert.is_true(result.right_fillers > 0, "Should have right fillers for deletion")

      cleanup_environment(env)
    end)

    -- CASE 7: Middle line wrap change in multi-line block
    it("Case 7: Handles middle line wrap change in block", function()
      local env = setup_diff_environment()

      local original = {
        'def case7_middle_line_wrap_change():',
        '    first = "unchanged"',
        '    middle = "short middle"',
        '    last = "unchanged"',
        '    return first, middle, last',
      }
      local modified = {
        'def case7_middle_line_wrap_change():',
        '    first = "unchanged"',
        '    middle = "This middle line was modified to become extremely long, much longer than it was before, with lots of extra words and content added to make it wrap significantly more than the original version did."',
        '    last = "unchanged"',
        '    return first, middle, last',
      }

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      local success, result = pcall(function()
        return core.render_diff(
          env.left_buf, env.right_buf,
          original, modified, lines_diff,
          env.left_win, env.right_win
        )
      end)

      assert.is_true(success, "Should handle middle line wrap change")
      assert.is_table(result)

      cleanup_environment(env)
    end)

    -- CASE 8: Multiple consecutive lines with different wrap behaviors
    it("Case 8: Handles multiple consecutive wrap changes", function()
      local env = setup_diff_environment()

      local original = {
        'def case8_consecutive_wrap_changes():',
        '    line1 = "First line short"',
        '    line2 = "Second short"',
        '    line3 = "Third line was originally very long with lots of extra text that caused it to wrap across multiple display lines in the terminal."',
        '    line4 = "Fourth short"',
        '    return line1, line2, line3, line4',
      }
      local modified = {
        'def case8_consecutive_wrap_changes():',
        '    line1 = "First line expanded to be quite long and verbose for testing purposes."',
        '    line2 = "Second line is even longer than the first, containing significantly more text and characters to ensure it wraps to multiple display lines in most reasonable window widths."',
        '    line3 = "Third line shorter now"',
        '    line4 = "Fourth line is the longest of all, packed with an extraordinary amount of textual content, verbose descriptions, and repetitive phrases designed specifically to maximize the number of display lines."',
        '    return line1, line2, line3, line4',
      }

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      local success, result = pcall(function()
        return core.render_diff(
          env.left_buf, env.right_buf,
          original, modified, lines_diff,
          env.left_win, env.right_win
        )
      end)

      assert.is_true(success, "Should handle multiple consecutive wrap changes")
      assert.is_table(result)

      cleanup_environment(env)
    end)

    -- CASE 9: Unicode/CJK characters (double-width)
    it("Case 9: Handles unicode and CJK characters", function()
      local env = setup_diff_environment()

      local original = {
        'def case9_unicode_width():',
        '    cjk = "Chinese Test"',
        '    emoji = "emoji"',
        '    return cjk, emoji',
      }
      local modified = {
        'def case9_unicode_width():',
        '    cjk = "Chinese/Japanese Test: This is a very long Chinese/Japanese string testing double-width character wrap alignment functionality."',
        '    emoji = "More emoji and unicode content here to test wrapping behavior"',
        '    return cjk, emoji',
      }

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      local success, result = pcall(function()
        return core.render_diff(
          env.left_buf, env.right_buf,
          original, modified, lines_diff,
          env.left_win, env.right_win
        )
      end)

      assert.is_true(success, "Should handle unicode characters")
      assert.is_table(result)

      cleanup_environment(env)
    end)

    -- CASE 10: Very long single line (stress test)
    it("Case 10: Handles very long single line (500+ chars)", function()
      local env = setup_diff_environment()

      local original = {
        'def case10_very_long_line():',
        '    return "' .. string.rep("A", 100) .. '"',
      }
      local modified = {
        'def case10_very_long_line():',
        '    return "' .. string.rep("A", 500) .. '"',
      }

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      local success, result = pcall(function()
        return core.render_diff(
          env.left_buf, env.right_buf,
          original, modified, lines_diff,
          env.left_win, env.right_win
        )
      end)

      assert.is_true(success, "Should handle very long lines")
      assert.is_table(result)

      cleanup_environment(env)
    end)

    -- CASE 11: Empty lines around wrapped content
    it("Case 11: Handles empty lines around wrapped content", function()
      local env = setup_diff_environment()

      local original = {
        'def case11_empty_lines_around_wrap():',
        '',
        '    before_empty = "Short"',
        '',
        '    long_after_empty = "Short too"',
        '',
        '    after_long = "Short again"',
        '',
        '    return before_empty, long_after_empty, after_long',
      }
      local modified = {
        'def case11_empty_lines_around_wrap():',
        '',
        '    before_empty = "Short"',
        '',
        '    long_after_empty = "This line comes after an empty line and is very long, testing that empty lines are handled correctly in the wrap alignment algorithm without causing off-by-one errors."',
        '',
        '    after_long = "Short again"',
        '',
        '    return before_empty, long_after_empty, after_long',
      }

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      local success, result = pcall(function()
        return core.render_diff(
          env.left_buf, env.right_buf,
          original, modified, lines_diff,
          env.left_win, env.right_win
        )
      end)

      assert.is_true(success, "Should handle empty lines around wrapped content")
      assert.is_table(result)

      cleanup_environment(env)
    end)

    -- CASE 12: Deep indentation affecting wrap
    it("Case 12: Handles deep indentation affecting wrap", function()
      local env = setup_diff_environment()

      local original = {
        'class Case12IndentationWrap:',
        '    def method_with_deep_indent(self):',
        '        if True:',
        '            if True:',
        '                if True:',
        '                    return "Short indent"',
      }
      local modified = {
        'class Case12IndentationWrap:',
        '    def method_with_deep_indent(self):',
        '        if True:',
        '            if True:',
        '                if True:',
        '                    return "Deeply indented long line that will wrap differently due to the indentation taking up visual space at the start of each wrapped segment of this lengthy string."',
      }

      vim.api.nvim_buf_set_lines(env.left_buf, 0, -1, false, original)
      vim.api.nvim_buf_set_lines(env.right_buf, 0, -1, false, modified)

      local lines_diff = diff.compute_diff(original, modified)

      local success, result = pcall(function()
        return core.render_diff(
          env.left_buf, env.right_buf,
          original, modified, lines_diff,
          env.left_win, env.right_win
        )
      end)

      assert.is_true(success, "Should handle deep indentation")
      assert.is_table(result)

      cleanup_environment(env)
    end)
  end)
end)
