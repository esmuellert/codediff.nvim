-- Test: Auto-scroll to first hunk
-- Validates that the diff view centers on the first change and activates scroll sync
-- Run with: nvim --headless -c "luafile tests/test_autoscroll.lua" -c "quit"

vim.opt.rtp:prepend(".")
vim.opt.swapfile = false  -- Disable swap files for tests
local render = require("vscode-diff.render")
local diff = require("vscode-diff.diff")

print("=== Test: Auto-scroll to First Hunk ===\n")

local test_count = 0
local pass_count = 0

local function test(name, fn)
  test_count = test_count + 1
  io.write(string.format("[%d] %s ... ", test_count, name))
  local ok, err = pcall(fn)
  if ok then
    pass_count = pass_count + 1
    print("✓")
  else
    print("✗")
    print("  Error: " .. tostring(err))
    os.exit(1)
  end
end

-- Setup highlights
render.setup_highlights()

-- Test 1: Change in middle of file
test("Scrolls to change in middle of file", function()
  local original_lines = {}
  local modified_lines = {}

  for i = 1, 20 do
    table.insert(original_lines, "unchanged line " .. i)
    table.insert(modified_lines, "unchanged line " .. i)
  end

  table.insert(original_lines, "original line 21")
  table.insert(modified_lines, "modified line 21")

  for i = 22, 40 do
    table.insert(original_lines, "unchanged line " .. i)
    table.insert(modified_lines, "unchanged line " .. i)
  end

  -- Write files to disk
  vim.fn.writefile(original_lines, "/tmp/test_left.txt")
  vim.fn.writefile(modified_lines, "/tmp/test_right.txt")

  local lines_diff = diff.compute_diff(original_lines, modified_lines)
  local view = render.create_diff_view(original_lines, modified_lines, lines_diff, {
    left_type = render.BufferType.REAL_FILE,
    left_config = { file_path = "/tmp/test_left.txt" },
    right_type = render.BufferType.REAL_FILE,
    right_config = { file_path = "/tmp/test_right.txt" },
  })
  
  -- Wait for vim.schedule to complete
  vim.cmd("redraw")
  vim.wait(100)

  local left_cursor = vim.api.nvim_win_get_cursor(view.left_win)
  local right_cursor = vim.api.nvim_win_get_cursor(view.right_win)

  assert(left_cursor[1] == 21, "Left cursor should be at line 21")
  assert(right_cursor[1] == 21, "Right cursor should be at line 21")
end)

-- Test 2: Change at beginning
test("Scrolls to change at beginning", function()
  local original_lines = {"old line 1", "unchanged 2", "unchanged 3"}
  local modified_lines = {"new line 1", "unchanged 2", "unchanged 3"}

  -- Write files to disk
  vim.fn.writefile(original_lines, "/tmp/test_left2.txt")
  vim.fn.writefile(modified_lines, "/tmp/test_right2.txt")

  local lines_diff = diff.compute_diff(original_lines, modified_lines)
  local view = render.create_diff_view(original_lines, modified_lines, lines_diff, {
    left_type = render.BufferType.REAL_FILE,
    left_config = { file_path = "/tmp/test_left2.txt" },
    right_type = render.BufferType.REAL_FILE,
    right_config = { file_path = "/tmp/test_right2.txt" },
  })

  -- Wait for vim.schedule to complete
  vim.cmd("redraw")
  vim.wait(100)

  local left_cursor = vim.api.nvim_win_get_cursor(view.left_win)
  local right_cursor = vim.api.nvim_win_get_cursor(view.right_win)

  assert(left_cursor[1] == 1, "Cursor should be at line 1")
  assert(right_cursor[1] == 1, "Cursor should be at line 1")
end)

-- Test 3: Large file centering
test("Centers line in large file", function()
  local original_lines = {}
  local modified_lines = {}

  for i = 1, 50 do
    table.insert(original_lines, "unchanged line " .. i)
    table.insert(modified_lines, "unchanged line " .. i)
  end

  table.insert(original_lines, "original line 51")
  table.insert(modified_lines, "MODIFIED line 51")

  for i = 52, 100 do
    table.insert(original_lines, "unchanged line " .. i)
    table.insert(modified_lines, "unchanged line " .. i)
  end

  -- Write files to disk
  vim.fn.writefile(original_lines, "/tmp/test_left3.txt")
  vim.fn.writefile(modified_lines, "/tmp/test_right3.txt")

  local lines_diff = diff.compute_diff(original_lines, modified_lines)
  local view = render.create_diff_view(original_lines, modified_lines, lines_diff, {
    left_type = render.BufferType.REAL_FILE,
    left_config = { file_path = "/tmp/test_left3.txt" },
    right_type = render.BufferType.REAL_FILE,
    right_config = { file_path = "/tmp/test_right3.txt" },
  })

  -- Wait for vim.schedule to complete
  vim.cmd("redraw")
  vim.wait(100)

  local cursor = vim.api.nvim_win_get_cursor(view.right_win)
  assert(cursor[1] == 51, "Cursor should be at line 51")
end)

-- Test 4: No changes
test("Handles no changes gracefully", function()
  local lines = {"line 1", "line 2", "line 3"}
  local lines_diff = diff.compute_diff(lines, lines)
  local view = render.create_diff_view(lines, lines, lines_diff, {
    left_type = render.BufferType.REAL_FILE,
    left_config = { file_path = "/tmp/test_left4.txt" },
    right_type = render.BufferType.REAL_FILE,
    right_config = { file_path = "/tmp/test_right4.txt" },
  })

  vim.cmd("redraw")

  local cursor = vim.api.nvim_win_get_cursor(view.right_win)
  assert(cursor[1] == 1, "Cursor should be at line 1 when no changes")
end)

-- Test 5: Right window is active (for scroll sync)
test("Right window is active after scroll", function()
  local original = {}
  local modified = {}

  for i = 1, 30 do
    original[i] = "Line " .. i
    modified[i] = "Line " .. i
  end

  original[15] = "OLD line 15"
  modified[15] = "NEW line 15"

  local lines_diff = diff.compute_diff(original, modified)
  local view = render.create_diff_view(original, modified, lines_diff, {
    left_type = render.BufferType.REAL_FILE,
    left_config = { file_path = "/tmp/test_left5.txt" },
    right_type = render.BufferType.REAL_FILE,
    right_config = { file_path = "/tmp/test_right5.txt" },
  })

  vim.cmd("redraw")

  local current_win = vim.api.nvim_get_current_win()
  assert(current_win == view.right_win, "Right window should be active for scroll sync")
end)

print(string.format("\n=================================================="))
print(string.format("✓ All %d tests passed", pass_count))
