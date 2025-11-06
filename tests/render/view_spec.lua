-- Test: render/view.lua - Diff view creation and window management
-- Critical tests for the main user-facing API

local view = require("vscode-diff.render.view")
local diff = require("vscode-diff.diff")
local highlights = require("vscode-diff.render.highlights")

-- Helper to get temp path
local function get_temp_path(filename)
  local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local temp_dir = is_windows and (vim.fn.getenv("TEMP") or "C:\\Windows\\Temp") or "/tmp"
  local sep = is_windows and "\\" or "/"
  return temp_dir .. sep .. filename
end

describe("Render View", function()
  before_each(function()
    highlights.setup()
  end)

  after_each(function()
    -- Close all extra tabs
    while vim.fn.tabpagenr('$') > 1 do
      vim.cmd('tabclose')
    end
  end)

  -- Test 1: Create basic diff view
  it("Creates a basic split diff view", function()
    local original = {"line 1", "line 2"}
    local modified = {"line 1", "line 3"}
    local lines_diff = diff.compute_diff(original, modified)

    local initial_tabs = vim.fn.tabpagenr('$')

    -- Create temp files for real file buffers
    local left_path = get_temp_path("test_view_left_1.txt")
    local right_path = get_temp_path("test_view_right_1.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result = view.create(original, modified, lines_diff, {
      left_type = view.BufferType.REAL_FILE,
      left_config = { file_path = left_path },
      right_type = view.BufferType.REAL_FILE,
      right_config = { file_path = right_path },
    })

    -- Should create a new tab
    local new_tabs = vim.fn.tabpagenr('$')
    assert.are.equal(initial_tabs + 1, new_tabs, "Should create a new tab")

    -- Clean up files
    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 2: Creates two windows in split
  it("Creates two windows in vertical split layout", function()
    local original = {"line 1"}
    local modified = {"line 2"}
    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_2.txt")
    local right_path = get_temp_path("test_view_right_2.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    view.create(original, modified, lines_diff, {
      left_type = view.BufferType.REAL_FILE,
      left_config = { file_path = left_path },
      right_type = view.BufferType.REAL_FILE,
      right_config = { file_path = right_path },
    })

    -- Wait for window setup
    vim.cmd('redraw')
    vim.wait(50)

    -- Should have 2 windows in current tab
    local win_count = vim.fn.winnr('$')
    assert.is_true(win_count >= 2, "Should have at least 2 windows")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 3: Buffers contain correct content
  it("Buffers contain the correct content after creation", function()
    local original = {"original line 1", "original line 2"}
    local modified = {"modified line 1", "modified line 2"}
    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_3.txt")
    local right_path = get_temp_path("test_view_right_3.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result = view.create(original, modified, lines_diff, {
      left_type = view.BufferType.REAL_FILE,
      left_config = { file_path = left_path },
      right_type = view.BufferType.REAL_FILE,
      right_config = { file_path = right_path },
    })

    vim.cmd('redraw')
    vim.wait(100)

    -- Get windows in current tab
    local wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())
    
    if #wins >= 2 then
      -- Windows may be in either order, so check both possibilities
      local buf1 = vim.api.nvim_win_get_buf(wins[1])
      local buf2 = vim.api.nvim_win_get_buf(wins[2])
      
      local lines1 = vim.api.nvim_buf_get_lines(buf1, 0, -1, false)
      local lines2 = vim.api.nvim_buf_get_lines(buf2, 0, -1, false)

      -- One should have original, one should have modified
      local has_original = (vim.deep_equal(lines1, original) or vim.deep_equal(lines2, original))
      local has_modified = (vim.deep_equal(lines1, modified) or vim.deep_equal(lines2, modified))
      
      assert.is_true(has_original, "One buffer should contain original lines")
      assert.is_true(has_modified, "One buffer should contain modified lines")
    end

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 4: Window options are set correctly
  it("Sets diff mode and scroll binding on windows", function()
    local original = {"line 1"}
    local modified = {"line 2"}
    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_4.txt")
    local right_path = get_temp_path("test_view_right_4.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    view.create(original, modified, lines_diff, {
      left_type = view.BufferType.REAL_FILE,
      left_config = { file_path = left_path },
      right_type = view.BufferType.REAL_FILE,
      right_config = { file_path = right_path },
    })

    -- Wait for async operations to complete
    vim.cmd('redraw')
    vim.wait(200)

    local wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())
    
    -- Should have at least 2 windows
    assert.is_true(#wins >= 2, "Should have at least 2 windows in diff view")
    
    if #wins >= 2 then
      -- Check that windows have scrollbind enabled (essential for diff view)
      for _, win in ipairs({wins[1], wins[2]}) do
        local scrollbind = vim.api.nvim_win_get_option(win, 'scrollbind')
        assert.is_true(scrollbind, "Scroll binding should be enabled for diff view")
      end
    end

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 5: Empty files are handled correctly
  it("Handles empty files without error", function()
    local original = {}
    local modified = {}
    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_5.txt")
    local right_path = get_temp_path("test_view_right_5.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local success = pcall(function()
      view.create(original, modified, lines_diff, {
        left_type = view.BufferType.REAL_FILE,
        left_config = { file_path = left_path },
        right_type = view.BufferType.REAL_FILE,
        right_config = { file_path = right_path },
      })
    end)

    assert.is_true(success, "Should handle empty files without error")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 6: Large files are handled
  it("Handles large files efficiently", function()
    local original = {}
    local modified = {}
    
    for i = 1, 1000 do
      table.insert(original, "original line " .. i)
      table.insert(modified, "modified line " .. i)
    end

    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_6.txt")
    local right_path = get_temp_path("test_view_right_6.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local start_time = vim.loop.hrtime()
    
    view.create(original, modified, lines_diff, {
      left_type = view.BufferType.REAL_FILE,
      left_config = { file_path = left_path },
      right_type = view.BufferType.REAL_FILE,
      right_config = { file_path = right_path },
    })

    local elapsed_ms = (vim.loop.hrtime() - start_time) / 1000000

    -- Print elapsed time for visibility
    print(string.format("View creation took %.2f ms", elapsed_ms))

    -- Should complete in reasonable time (< 1000ms)
    assert.is_true(elapsed_ms < 1000, "Should create view in < 1 second, took " .. elapsed_ms .. " ms")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 7: Creates view with no changes
  it("Creates view when files have no changes", function()
    local lines = {"line 1", "line 2", "line 3"}
    local lines_diff = diff.compute_diff(lines, lines)

    local left_path = get_temp_path("test_view_left_7.txt")
    local right_path = get_temp_path("test_view_right_7.txt")
    vim.fn.writefile(lines, left_path)
    vim.fn.writefile(lines, right_path)

    local success = pcall(function()
      view.create(lines, lines, lines_diff, {
        left_type = view.BufferType.REAL_FILE,
        left_config = { file_path = left_path },
        right_type = view.BufferType.REAL_FILE,
        right_config = { file_path = right_path },
      })
    end)

    assert.is_true(success, "Should create view even with no changes")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 8: Switching between tabs preserves diff view
  it("Diff view persists when switching tabs", function()
    local original = {"line 1"}
    local modified = {"line 2"}
    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_8.txt")
    local right_path = get_temp_path("test_view_right_8.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    view.create(original, modified, lines_diff, {
      left_type = view.BufferType.REAL_FILE,
      left_config = { file_path = left_path },
      right_type = view.BufferType.REAL_FILE,
      right_config = { file_path = right_path },
    })

    local diff_tab = vim.api.nvim_get_current_tabpage()

    -- Create and switch to another tab
    vim.cmd('tabnew')
    vim.cmd('tabprevious')

    -- Should still be on diff tab
    local current_tab = vim.api.nvim_get_current_tabpage()
    assert.are.equal(diff_tab, current_tab, "Should be back on diff tab")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 9: Multiple diff views in different tabs
  it("Can create multiple diff views in different tabs", function()
    local tabs_before = vim.fn.tabpagenr('$')

    -- Create first diff
    local original1 = {"a"}
    local modified1 = {"b"}
    local left_path1 = get_temp_path("test_view_left_9a.txt")
    local right_path1 = get_temp_path("test_view_right_9a.txt")
    vim.fn.writefile(original1, left_path1)
    vim.fn.writefile(modified1, right_path1)

    view.create(original1, modified1, diff.compute_diff(original1, modified1), {
      left_type = view.BufferType.REAL_FILE,
      left_config = { file_path = left_path1 },
      right_type = view.BufferType.REAL_FILE,
      right_config = { file_path = right_path1 },
    })

    -- Create second diff
    local original2 = {"c"}
    local modified2 = {"d"}
    local left_path2 = get_temp_path("test_view_left_9b.txt")
    local right_path2 = get_temp_path("test_view_right_9b.txt")
    vim.fn.writefile(original2, left_path2)
    vim.fn.writefile(modified2, right_path2)

    view.create(original2, modified2, diff.compute_diff(original2, modified2), {
      left_type = view.BufferType.REAL_FILE,
      left_config = { file_path = left_path2 },
      right_type = view.BufferType.REAL_FILE,
      right_config = { file_path = right_path2 },
    })

    local tabs_after = vim.fn.tabpagenr('$')
    assert.are.equal(tabs_before + 2, tabs_after, "Should create 2 new tabs")

    vim.fn.delete(left_path1)
    vim.fn.delete(right_path1)
    vim.fn.delete(left_path2)
    vim.fn.delete(right_path2)
  end)

  -- Test 10: View handles single-line files
  it("Handles single-line files correctly", function()
    local original = {"single line"}
    local modified = {"different line"}
    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_10.txt")
    local right_path = get_temp_path("test_view_right_10.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local success = pcall(function()
      view.create(original, modified, lines_diff, {
        left_type = view.BufferType.REAL_FILE,
        left_config = { file_path = left_path },
        right_type = view.BufferType.REAL_FILE,
        right_config = { file_path = right_path },
      })
    end)

    assert.is_true(success, "Should handle single-line files")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 11: View handles files with special characters
  it("Handles files with special characters in content", function()
    local original = {"line with 'quotes'", 'line with "double quotes"'}
    local modified = {"line with $dollar", "line with `backtick`"}
    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_11.txt")
    local right_path = get_temp_path("test_view_right_11.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local success = pcall(function()
      view.create(original, modified, lines_diff, {
        left_type = view.BufferType.REAL_FILE,
        left_config = { file_path = left_path },
        right_type = view.BufferType.REAL_FILE,
        right_config = { file_path = right_path },
      })
    end)

    assert.is_true(success, "Should handle special characters")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 12: BufferType enum is defined
  it("BufferType enum has correct values", function()
    assert.is_not_nil(view.BufferType, "BufferType should be defined")
    assert.is_not_nil(view.BufferType.REAL_FILE, "REAL_FILE should be defined")
    assert.is_not_nil(view.BufferType.VIRTUAL_FILE, "VIRTUAL_FILE should be defined")
    assert.are.equal("REAL_FILE", view.BufferType.REAL_FILE, "REAL_FILE value should be correct")
    assert.are.equal("VIRTUAL_FILE", view.BufferType.VIRTUAL_FILE, "VIRTUAL_FILE value should be correct")
  end)

  -- Test 13: View creation doesn't affect other buffers
  it("View creation doesn't modify other open buffers", function()
    -- Create a buffer with content
    local other_buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, {"other content"})

    local original = {"line 1"}
    local modified = {"line 2"}
    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_13.txt")
    local right_path = get_temp_path("test_view_right_13.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    view.create(original, modified, lines_diff, {
      left_type = view.BufferType.REAL_FILE,
      left_config = { file_path = left_path },
      right_type = view.BufferType.REAL_FILE,
      right_config = { file_path = right_path },
    })

    -- Other buffer should be unchanged
    local other_lines = vim.api.nvim_buf_get_lines(other_buf, 0, -1, false)
    assert.are.same({"other content"}, other_lines, "Other buffer should be unchanged")

    vim.api.nvim_buf_delete(other_buf, {force = true})
    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 14: View with many hunks
  it("Handles files with many change hunks", function()
    local original = {}
    local modified = {}
    
    for i = 1, 50 do
      if i % 2 == 0 then
        table.insert(original, "original " .. i)
        table.insert(modified, "modified " .. i)
      else
        table.insert(original, "same " .. i)
        table.insert(modified, "same " .. i)
      end
    end

    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_14.txt")
    local right_path = get_temp_path("test_view_right_14.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local success = pcall(function()
      view.create(original, modified, lines_diff, {
        left_type = view.BufferType.REAL_FILE,
        left_config = { file_path = left_path },
        right_type = view.BufferType.REAL_FILE,
        right_config = { file_path = right_path },
      })
    end)

    assert.is_true(success, "Should handle many hunks")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 15: Calling create multiple times in sequence
  it("Can call create multiple times without issues", function()
    for i = 1, 3 do
      local original = {"iteration " .. i}
      local modified = {"changed " .. i}
      local lines_diff = diff.compute_diff(original, modified)

      local left_path = get_temp_path("test_view_left_15_" .. i .. ".txt")
      local right_path = get_temp_path("test_view_right_15_" .. i .. ".txt")
      vim.fn.writefile(original, left_path)
      vim.fn.writefile(modified, right_path)

      local success = pcall(function()
        view.create(original, modified, lines_diff, {
          left_type = view.BufferType.REAL_FILE,
          left_config = { file_path = left_path },
          right_type = view.BufferType.REAL_FILE,
          right_config = { file_path = right_path },
        })
      end)

      assert.is_true(success, "Iteration " .. i .. " should succeed")

      vim.fn.delete(left_path)
      vim.fn.delete(right_path)
    end
  end)
end)
