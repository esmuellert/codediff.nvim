-- Test: Auto-scroll to first hunk
-- Validates that the diff view centers on the first change and activates scroll sync

local render = require("vscode-diff.render")
local diff = require("vscode-diff.diff")

-- Helper function to get platform-agnostic temp directory
local function get_temp_dir()
  local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  if is_windows then
    return vim.fn.getenv("TEMP") or vim.fn.getenv("TMP") or "C:\\Windows\\Temp"
  else
    return "/tmp"
  end
end

local function get_temp_path(filename)
  return get_temp_dir() .. (vim.fn.has("win32") == 1 and "\\" or "/") .. filename
end

describe("Auto-scroll to first hunk", function()
  before_each(function()
    -- Setup highlights (was done globally in original)
    render.setup_highlights()
  end)

  after_each(function()
    -- Clean up any lingering tabs
    while vim.fn.tabpagenr('$') > 1 do
      vim.cmd('tabclose!')
    end
  end)

  -- Test 1: Change in middle of file
  it("Scrolls to change in middle of file", function()
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

    -- Write files to disk with unique names
    local left_path = get_temp_path("autoscroll_test1_left.txt")
    local right_path = get_temp_path("autoscroll_test1_right.txt")
    vim.fn.writefile(original_lines, left_path)
    vim.fn.writefile(modified_lines, right_path)

    local lines_diff = diff.compute_diff(original_lines, modified_lines)
    if not lines_diff then error("lines_diff is nil") end
    local view = render.create_diff_view(original_lines, modified_lines, lines_diff, {
      left_type = render.BufferType.REAL_FILE,
      left_config = { file_path = left_path },
      right_type = render.BufferType.REAL_FILE,
      right_config = { file_path = right_path },
    })

    -- Wait for vim.schedule to complete
    vim.cmd("redraw")
    vim.wait(100)
    if not view then error("view is nil") end

    local left_cursor = vim.api.nvim_win_get_cursor(view.left_win)
    local right_cursor = vim.api.nvim_win_get_cursor(view.right_win)

    assert(21 == left_cursor[1], "Left cursor should be at line 21")
    assert(21 == right_cursor[1], "Right cursor should be at line 21")

    -- Cleanup
    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 2: Change at beginning
  it("Scrolls to change at beginning", function()
    local original_lines = {"old line 1", "unchanged 2", "unchanged 3"}
    local modified_lines = {"new line 1", "unchanged 2", "unchanged 3"}

    -- Write files to disk with unique names
    local left_path = get_temp_path("autoscroll_test2_left.txt")
    local right_path = get_temp_path("autoscroll_test2_right.txt")
    vim.fn.writefile(original_lines, left_path)
    vim.fn.writefile(modified_lines, right_path)

    local lines_diff = diff.compute_diff(original_lines, modified_lines)
    if not lines_diff then error("lines_diff is nil") end
    local view = render.create_diff_view(original_lines, modified_lines, lines_diff, {
      left_type = render.BufferType.REAL_FILE,
      left_config = { file_path = left_path },
      right_type = render.BufferType.REAL_FILE,
      right_config = { file_path = right_path },
    })

    -- Wait for vim.schedule to complete
    vim.cmd("redraw")
    vim.wait(100)
    if not view then error("view is nil") end

    local left_cursor = vim.api.nvim_win_get_cursor(view.left_win)
    local right_cursor = vim.api.nvim_win_get_cursor(view.right_win)

    assert(1 == left_cursor[1], "Cursor should be at line 1")
    assert(1 == right_cursor[1], "Cursor should be at line 1")

    -- Cleanup
    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 3: Large file centering
  it("Centers line in large file", function()
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
    local left_path = get_temp_path("autoscroll_test3_left.txt")
    local right_path = get_temp_path("autoscroll_test3_right.txt")
    vim.fn.writefile(original_lines, left_path)
    vim.fn.writefile(modified_lines, right_path)

    local lines_diff = diff.compute_diff(original_lines, modified_lines)
    if not lines_diff then error("lines_diff is nil") end
    local view = render.create_diff_view(original_lines, modified_lines, lines_diff, {
      left_type = render.BufferType.REAL_FILE,
      left_config = { file_path = left_path },
      right_type = render.BufferType.REAL_FILE,
      right_config = { file_path = right_path },
    })

    -- Wait for vim.schedule to complete
    vim.cmd("redraw")
    vim.wait(100)
    if not view then error("view is nil") end

    local cursor = vim.api.nvim_win_get_cursor(view.right_win)
    assert(51 == cursor[1], "Cursor should be at line 51")
    -- Cleanup
    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 4: No changes
  it("Handles no changes gracefully", function()
    local lines = {"line 1", "line 2", "line 3"}
    local left_path = get_temp_path("autoscroll_test4_left.txt")
    local right_path = get_temp_path("autoscroll_test4_right.txt")

    local lines_diff = diff.compute_diff(lines, lines)
    if not lines_diff then error("lines_diff is nil") end
    local view = render.create_diff_view(lines, lines, lines_diff, {
      left_type = render.BufferType.REAL_FILE,
      left_config = { file_path = left_path },
      right_type = render.BufferType.REAL_FILE,
      right_config = { file_path = right_path },
    })

    vim.cmd("redraw")
    if not view then error("view is nil") end

    local cursor = vim.api.nvim_win_get_cursor(view.right_win)
    assert(1 == cursor[1], "Cursor should be at line 1 when no changes")

    -- Cleanup
    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 5: Right window is active (for scroll sync)
  it("Right window is active after scroll", function()
    local original = {}
    local modified = {}

    for i = 1, 30 do
      original[i] = "Line " .. i
      modified[i] = "Line " .. i
    end

    original[15] = "OLD line 15"
    modified[15] = "NEW line 15"

    local left_path = get_temp_path("autoscroll_test5_left.txt")
    local right_path = get_temp_path("autoscroll_test5_right.txt")

    local lines_diff = diff.compute_diff(original, modified)
    if not lines_diff then error("lines_diff is nil") end
    local view = render.create_diff_view(original, modified, lines_diff, {
      left_type = render.BufferType.REAL_FILE,
      left_config = { file_path = left_path },
      right_type = render.BufferType.REAL_FILE,
      right_config = { file_path = right_path },
    })

    if not view then error("view is nil") end
    vim.cmd("redraw")

    local current_win = vim.api.nvim_get_current_win()
    assert(view.right_win == current_win, "Right window should be active for scroll sync")

    -- Cleanup
    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)
end)
