-- Test: inline diff mode interactions
-- Verifies hunk navigation, diff operations, auto-refresh, lifecycle cleanup,
-- and re-render behaviour in the inline diff layout.

local view = require("codediff.ui.view")
local diff = require("codediff.core.diff")
local highlights = require("codediff.ui.highlights")
local lifecycle = require("codediff.ui.lifecycle")
local navigation = require("codediff.ui.view.navigation")
local path = require("codediff.core.path")

-- Helper to get OS-appropriate temp path
local function get_temp_path(filename)
  local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local temp_dir = is_windows and (vim.fn.getenv("TEMP") or "C:\\Windows\\Temp") or "/tmp"
  local sep = is_windows and "\\" or "/"
  -- Append PID to guarantee uniqueness across runs
  local subdir = temp_dir .. sep .. "codediff_inline_test_" .. vim.fn.getpid()
  vim.fn.mkdir(subdir, "p")
  return subdir .. sep .. filename
end

-- Monotonic counter for unique temp file names across tests
local _file_counter = 0

-- Helper: create an inline diff view from two sets of lines.
-- Returns a context table with tabpage, session, buffer ids and temp paths.
local function create_inline_view(original_lines, modified_lines)
  _file_counter = _file_counter + 1
  local left_path = get_temp_path("inline_test_left_" .. _file_counter .. ".txt")
  local right_path = get_temp_path("inline_test_right_" .. _file_counter .. ".txt")
  vim.fn.writefile(original_lines, left_path)
  vim.fn.writefile(modified_lines, right_path)

  view.create({
    git_root = nil,
    original = path.make_ref(left_path, nil),
    modified = path.make_ref(right_path, nil),
    original_revision = nil,
    modified_revision = nil,
  })

  vim.cmd("redraw")
  vim.wait(200)

  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)

  return {
    tabpage = tabpage,
    session = session,
    modified_bufnr = session and session.modified_bufnr,
    original_bufnr = session and session.original_bufnr,
    left_path = left_path,
    right_path = right_path,
  }
end

describe("Inline diff mode interactions", function()
  before_each(function()
    -- Ensure no swap files interfere (user init.lua may re-enable swapfile)
    vim.opt.swapfile = false
    require("codediff").setup({ diff = { layout = "inline" } })
    highlights.setup()
  end)

  after_each(function()
    -- Restore default layout so other test suites are unaffected
    require("codediff").setup({ diff = { layout = "side-by-side" } })

    -- Close all extra tabs
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose")
    end
  end)

  -- =========================================================================
  -- 1. Hunk navigation – next_hunk
  -- =========================================================================
  it("next_hunk moves cursor to the first hunk from before any hunk", function()
    -- Three separated hunks: changes at lines 2, 5, 8
    local original = {
      "line1", "orig2", "line3", "line4", "orig5",
      "line6", "line7", "orig8", "line9", "line10",
    }
    local modified = {
      "line1", "mod2", "line3", "line4", "mod5",
      "line6", "line7", "mod8", "line9", "line10",
    }

    local ctx = create_inline_view(original, modified)
    assert.is_truthy(ctx.session, "Session should exist")
    assert.is_truthy(ctx.session.stored_diff_result, "Diff result should exist")
    assert.is_truthy(ctx.session.stored_diff_result.changes, "Changes should exist")
    assert.is_true(#ctx.session.stored_diff_result.changes > 0, "Should have hunks")

    -- Position cursor before first hunk
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local ok = navigation.next_hunk()
    assert.is_true(ok, "next_hunk should succeed")

    local cursor = vim.api.nvim_win_get_cursor(0)
    local first_hunk = ctx.session.stored_diff_result.changes[1]
    assert.equal(first_hunk.modified.start_line, cursor[1],
      "Cursor should be on the first hunk's modified start_line")

    vim.fn.delete(ctx.left_path)
    vim.fn.delete(ctx.right_path)
  end)

  -- =========================================================================
  -- 2. Hunk navigation – prev_hunk
  -- =========================================================================
  it("prev_hunk moves cursor to the last hunk from after all hunks", function()
    local original = {
      "line1", "orig2", "line3", "line4", "orig5",
      "line6", "line7", "orig8", "line9", "line10",
    }
    local modified = {
      "line1", "mod2", "line3", "line4", "mod5",
      "line6", "line7", "mod8", "line9", "line10",
    }

    local ctx = create_inline_view(original, modified)
    assert.is_truthy(ctx.session, "Session should exist")
    local changes = ctx.session.stored_diff_result.changes
    assert.is_true(#changes > 0, "Should have hunks")

    -- Position cursor after the last hunk
    local line_count = vim.api.nvim_buf_line_count(ctx.modified_bufnr)
    vim.api.nvim_win_set_cursor(0, { line_count, 0 })

    local ok = navigation.prev_hunk()
    assert.is_true(ok, "prev_hunk should succeed")

    local cursor = vim.api.nvim_win_get_cursor(0)
    local last_hunk = changes[#changes]
    assert.equal(last_hunk.modified.start_line, cursor[1],
      "Cursor should be on the last hunk's modified start_line")

    vim.fn.delete(ctx.left_path)
    vim.fn.delete(ctx.right_path)
  end)

  -- =========================================================================
  -- 3. Diff-get (do) reverts a hunk to its original content
  -- =========================================================================
  it("diff_get reverts a modified hunk to the original content", function()
    local original = { "line1", "original_content", "line3" }
    local modified = { "line1", "changed_content", "line3" }

    local ctx = create_inline_view(original, modified)
    assert.is_truthy(ctx.session, "Session should exist")
    assert.is_truthy(ctx.original_bufnr, "Original buffer should exist")
    assert.is_truthy(ctx.modified_bufnr, "Modified buffer should exist")

    local changes = ctx.session.stored_diff_result.changes
    assert.is_true(#changes > 0, "Should have at least one hunk")

    local hunk = changes[1]

    -- Read original lines for this hunk
    local orig_start = hunk.original.start_line
    local orig_end = hunk.original.end_line
    local orig_hunk_lines = vim.api.nvim_buf_get_lines(
      ctx.original_bufnr, orig_start - 1, orig_end - 1, false
    )

    -- Replace the modified lines with original content (simulating diff-get)
    local mod_start = hunk.modified.start_line
    local mod_end = hunk.modified.end_line
    vim.bo[ctx.modified_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(
      ctx.modified_bufnr, mod_start - 1, mod_end - 1, false, orig_hunk_lines
    )

    local result_lines = vim.api.nvim_buf_get_lines(ctx.modified_bufnr, 0, -1, false)
    assert.are.same(original, result_lines,
      "After diff-get, modified buffer should match original content")

    vim.fn.delete(ctx.left_path)
    vim.fn.delete(ctx.right_path)
  end)

  -- =========================================================================
  -- 4. Auto-refresh re-renders after buffer modification
  -- =========================================================================
  it("auto-refresh updates diff result after buffer modification", function()
    local original = { "line1", "line2", "line3" }
    local modified = { "line1", "changed", "line3" }

    local ctx = create_inline_view(original, modified)
    assert.is_truthy(ctx.session, "Session should exist")
    assert.is_truthy(ctx.modified_bufnr, "Modified buffer should exist")

    -- Capture the initial change count
    local initial_changes = ctx.session.stored_diff_result.changes
    local initial_change_count = #initial_changes

    -- Modify the buffer: append a new line (creates an additional hunk)
    vim.bo[ctx.modified_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(ctx.modified_bufnr, -1, -1, false, { "appended_line" })

    -- Programmatic buffer changes (nvim_buf_set_lines) do not fire TextChanged,
    -- so trigger the auto-refresh pipeline manually.
    require("codediff.ui.refresh").buffer_changed(ctx.modified_bufnr)

    -- Wait for throttled refresh (THROTTLE_DELAY_MS = 200 + vim.schedule)
    vim.wait(500, function()
      local sess = lifecycle.get_session(ctx.tabpage)
      if not sess or not sess.stored_diff_result or not sess.stored_diff_result.changes then
        return false
      end
      return #sess.stored_diff_result.changes ~= initial_change_count
    end, 50)

    local updated_session = lifecycle.get_session(ctx.tabpage)
    assert.is_truthy(updated_session, "Session should still exist")
    assert.is_truthy(updated_session.stored_diff_result, "Diff result should exist")
    assert.is_not.equal(initial_change_count, #updated_session.stored_diff_result.changes,
      "Change count should differ after buffer modification")

    vim.fn.delete(ctx.left_path)
    vim.fn.delete(ctx.right_path)
  end)

  -- =========================================================================
  -- 5. Cleanup on tab close
  -- =========================================================================
  it("session is cleaned up when tab is closed", function()
    local original = { "line1" }
    local modified = { "line2" }

    local ctx = create_inline_view(original, modified)
    assert.is_truthy(ctx.session, "Session should exist before tab close")

    local tabpage = ctx.tabpage

    -- Close the diff tab
    vim.cmd("tabclose")
    vim.cmd("redraw")
    vim.wait(200)

    local session_after = lifecycle.get_session(tabpage)
    assert.is_nil(session_after, "Session should be nil after tab is closed")

    vim.fn.delete(ctx.left_path)
    vim.fn.delete(ctx.right_path)
  end)

  -- =========================================================================
  -- 6. Re-render clears old decorations and applies new ones
  -- =========================================================================
  it("rerender clears old extmarks and applies fresh decorations", function()
    local original = { "line1", "orig2", "line3" }
    local modified = { "line1", "mod2", "line3" }

    local ctx = create_inline_view(original, modified)
    assert.is_truthy(ctx.session, "Session should exist")
    assert.is_truthy(ctx.modified_bufnr, "Modified buffer should exist")

    local inline_ns = require("codediff.ui.inline").ns_inline

    -- Count extmarks after initial render
    local initial_extmarks = vim.api.nvim_buf_get_extmarks(
      ctx.modified_bufnr, inline_ns, 0, -1, {}
    )
    assert.is_true(#initial_extmarks > 0, "Should have extmarks after initial render")

    -- Modify buffer to remove the change (make it identical to original)
    vim.bo[ctx.modified_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(ctx.modified_bufnr, 0, -1, false, { "line1", "orig2", "line3" })

    -- Trigger re-render
    local inline_view = require("codediff.ui.view.inline_view")
    inline_view.rerender(ctx.tabpage)

    vim.cmd("redraw")
    vim.wait(100)

    -- After re-render with identical content, there should be no diff extmarks
    local updated_extmarks = vim.api.nvim_buf_get_extmarks(
      ctx.modified_bufnr, inline_ns, 0, -1, {}
    )
    assert.is_true(#updated_extmarks < #initial_extmarks,
      "Extmark count should decrease after removing the change (was "
        .. #initial_extmarks .. ", now " .. #updated_extmarks .. ")")

    vim.fn.delete(ctx.left_path)
    vim.fn.delete(ctx.right_path)
  end)

  -- ========================================================================
  -- Autoscroll tests
  -- ========================================================================

  -- Test 7: Autoscroll to change in middle of file
  it("Autoscroll jumps to first change in middle of file", function()
    local original = {}
    local modified = {}
    for i = 1, 20 do
      table.insert(original, "unchanged line " .. i)
      table.insert(modified, "unchanged line " .. i)
    end
    original[15] = "original line 15"
    modified[15] = "modified line 15"

    local ctx = create_inline_view(original, modified)
    assert.is_truthy(ctx.session, "Session should exist")

    -- With jump_to_first_change=true (default), cursor should be near the change
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.is_true(cursor[1] >= 14 and cursor[1] <= 16,
      "Cursor should be near line 15 (first change), got line " .. cursor[1])

    vim.fn.delete(ctx.left_path)
    vim.fn.delete(ctx.right_path)
  end)

  -- Test 8: Autoscroll to change at beginning
  it("Autoscroll jumps to change at beginning of file", function()
    local original = {"original first", "line 2", "line 3", "line 4", "line 5"}
    local modified = {"modified first", "line 2", "line 3", "line 4", "line 5"}

    local ctx = create_inline_view(original, modified)
    assert.is_truthy(ctx.session, "Session should exist")

    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.are.equal(1, cursor[1], "Cursor should be at line 1 (first change)")

    vim.fn.delete(ctx.left_path)
    vim.fn.delete(ctx.right_path)
  end)

  -- Test 9: Autoscroll handles no changes
  it("Autoscroll handles no changes gracefully", function()
    local lines = {"line 1", "line 2", "line 3"}

    local ctx = create_inline_view(lines, lines)
    assert.is_truthy(ctx.session, "Session should exist")

    -- Should not error, cursor stays at default position
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.is_truthy(cursor, "Cursor should be valid")

    vim.fn.delete(ctx.left_path)
    vim.fn.delete(ctx.right_path)
  end)

  -- Test 10: Autoscroll centers in large file
  it("Autoscroll centers change in large file", function()
    local original = {}
    local modified = {}
    for i = 1, 100 do
      table.insert(original, "line " .. i)
      table.insert(modified, "line " .. i)
    end
    original[50] = "original 50"
    modified[50] = "modified 50"

    local ctx = create_inline_view(original, modified)
    assert.is_truthy(ctx.session, "Session should exist")

    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.are.equal(50, cursor[1], "Cursor should be at line 50")

    vim.fn.delete(ctx.left_path)
    vim.fn.delete(ctx.right_path)
  end)

  -- ========================================================================
  -- Hunk textobject tests
  -- ========================================================================

  -- Test 11: yih yanks a multi-line hunk in inline mode
  it("Textobject yih yanks a multi-line hunk", function()
    local original = {"line 1", "line 2", "line 3", "line 4", "line 5"}
    local modified = {"line 1", "CHANGED 2", "CHANGED 3", "line 4", "line 5"}

    local ctx = create_inline_view(original, modified)
    assert.is_truthy(ctx.session, "Session should exist")
    assert.is_truthy(ctx.session.stored_diff_result, "Diff result should exist")

    vim.api.nvim_win_set_cursor(0, {2, 0})
    vim.fn.setreg("a", "")
    vim.cmd('normal "ayih')

    local yanked = vim.fn.getreg("a")
    assert.is_not_nil(yanked:match("CHANGED 2"), "Should contain CHANGED 2")
    assert.is_not_nil(yanked:match("CHANGED 3"), "Should contain CHANGED 3")
    assert.is_nil(yanked:match("line 1"), "Should not contain unchanged lines")

    vim.fn.delete(ctx.left_path)
    vim.fn.delete(ctx.right_path)
  end)

  -- Test 12: yih does nothing outside a hunk in inline mode
  it("Textobject yih does nothing outside a hunk", function()
    local original = {"line 1", "line 2", "line 3", "line 4"}
    local modified = {"line 1", "CHANGED 2", "line 3", "line 4"}

    local ctx = create_inline_view(original, modified)
    assert.is_truthy(ctx.session, "Session should exist")

    vim.api.nvim_win_set_cursor(0, {4, 0})
    vim.fn.setreg("a", "")
    vim.cmd('normal "ayih')

    local yanked = vim.fn.getreg("a")
    assert.are.equal("", yanked, "Should not yank anything outside a hunk")

    vim.fn.delete(ctx.left_path)
    vim.fn.delete(ctx.right_path)
  end)
end)
