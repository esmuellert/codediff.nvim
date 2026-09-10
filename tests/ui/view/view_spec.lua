-- Test: render/view.lua - Diff view creation and window management
-- Critical tests for the main user-facing API

local view = require("codediff.ui.view")
local diff = require("codediff.core.diff")
local highlights = require("codediff.ui.highlights")
local lifecycle = require("codediff.ui.lifecycle")
local path = require("codediff.core.path")

-- Helper to get temp path
local function get_temp_path(filename)
  local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local temp_dir = is_windows and (vim.fn.getenv("TEMP") or "C:\\Windows\\Temp") or "/tmp"
  local sep = is_windows and "\\" or "/"
  return temp_dir .. sep .. filename
end

-- Helper to create diff view using new API
local function create_test_diff_view(original_lines, modified_lines, left_path, right_path)
  local session_config = {
    git_root = nil,
    original = path.make_ref(left_path, nil),
    modified = path.make_ref(right_path, nil),
    original_revision = nil, -- Real files, not virtual
    modified_revision = nil,
  }

  local result = view.create(session_config)
  local tabpage = vim.api.nvim_get_current_tabpage()
  return result, tabpage
end

describe("Render View", function()
  before_each(function()
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    highlights.setup()
  end)

  after_each(function()
    -- Close all extra tabs
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose")
    end
  end)

  -- Test 1: Create basic diff view
  it("Creates a basic split diff view", function()
    local original = { "line 1", "line 2" }
    local modified = { "line 1", "line 3" }
    local lines_diff = diff.compute_diff(original, modified)

    local initial_tabs = vim.fn.tabpagenr("$")

    -- Create temp files for real file buffers
    local left_path = get_temp_path("test_view_left_1.txt")
    local right_path = get_temp_path("test_view_right_1.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    -- New API: create session first
    local result, tabpage = create_test_diff_view(original, modified, left_path, right_path)

    -- Should create a new tab
    local new_tabs = vim.fn.tabpagenr("$")
    assert.equal(initial_tabs + 1, new_tabs, "Should create a new tab")

    -- Clean up files
    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 2: Creates two windows in split
  it("Creates two windows in vertical split layout", function()
    local original = { "line 1" }
    local modified = { "line 2" }
    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_2.txt")
    local right_path = get_temp_path("test_view_right_2.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result, tabpage = create_test_diff_view(original, modified, left_path, right_path)

    -- Wait for window setup
    vim.cmd("redraw")
    vim.wait(50)

    -- Should have 2 windows in current tab
    local win_count = vim.fn.winnr("$")
    assert.is_true(win_count >= 2, "Should have at least 2 windows")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 3: Buffers contain correct content
  it("Buffers contain the correct content after creation", function()
    local original = { "original line 1", "original line 2" }
    local modified = { "modified line 1", "modified line 2" }
    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_3.txt")
    local right_path = get_temp_path("test_view_right_3.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result, tabpage = create_test_diff_view(original, modified, left_path, right_path)

    vim.cmd("redraw")
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
    local original = { "line 1" }
    local modified = { "line 2" }
    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_4.txt")
    local right_path = get_temp_path("test_view_right_4.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result, tabpage = create_test_diff_view(original, modified, left_path, right_path)

    -- Wait for async operations to complete
    vim.cmd("redraw")
    vim.wait(200)

    local wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())

    -- Should have at least 2 windows
    assert.is_true(#wins >= 2, "Should have at least 2 windows in diff view")

    -- Side-by-side diff panes use Neovim's native scrollbind.
    if #wins >= 2 then
      for _, win in ipairs({ wins[1], wins[2] }) do
        assert.is_true(vim.api.nvim_win_get_option(win, "scrollbind"), "Native scrollbind should be enabled on diff panes")
      end
    end

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 4b: Regression (#254) - duplicating a diff window must not carry the
  -- scroll mirroring into the copy. CodeDiff clears inherited scrollbind on
  -- windows that are not part of the active diff.
  it("Does not scroll-mirror a window split off a diff pane", function()
    local original = {}
    local modified = {}
    for i = 1, 200 do
      original[i] = string.format("line %03d", i)
      modified[i] = original[i]
    end
    modified[50] = "CHANGED 050"

    local left_path = get_temp_path("test_view_left_254.txt")
    local right_path = get_temp_path("test_view_right_254.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local _, tabpage = create_test_diff_view(original, modified, left_path, right_path)
    vim.cmd("redraw")
    vim.wait(200)

    local session = lifecycle.get_session(tabpage)
    assert.is_not_nil(session, "diff session should exist")
    local mod_win = session.modified_win

    for _, win in ipairs({ session.original_win, mod_win }) do
      assert.is_true(vim.wo[win].scrollbind, "scrollbind must be enabled on diff windows")
      assert.is_false(vim.wo[win].cursorbind, "cursorbind must stay off on diff windows")
      assert.is_false(vim.wo[win].diff, "diff must stay off on diff windows")
    end

    -- Duplicate the modified pane the way a user would (<C-w>s).
    vim.api.nvim_set_current_win(mod_win)
    vim.cmd("split")
    local clone = vim.api.nvim_get_current_win()
    assert.is_false(vim.wo[clone].scrollbind, "the split window must not inherit scrollbind")

    local function topline(win)
      return vim.api.nvim_win_call(win, function()
        return vim.fn.line("w0")
      end)
    end
    local clone_top = topline(clone)

    vim.api.nvim_set_current_win(mod_win)
    for _ = 1, 30 do
      vim.cmd("normal! \5") -- <C-e>
    end
    assert.is_true(topline(mod_win) > 1, "the diff pane should have scrolled")
    assert.are.equal(clone_top, topline(clone), "the split window must stay put")

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

    local pre_tabs = vim.fn.tabpagenr("$")
    local success, tabpage
    success = pcall(function()
      _, tabpage = create_test_diff_view(original, modified, left_path, right_path)
    end)
    assert.is_true(success, "Should handle empty files without error")

    -- A side-by-side view was actually created: new tab + registered session.
    assert.equal(pre_tabs + 1, vim.fn.tabpagenr("$"), "a new tab should exist for the diff view")
    assert.is_not_nil(tabpage)
    vim.wait(2000, function() return lifecycle.get_session(tabpage) ~= nil end, 25)
    local sess = lifecycle.get_session(tabpage)
    assert.is_not_nil(sess, "empty-file diff view must still register a session")
    assert.is_true(vim.api.nvim_buf_is_valid(sess.original_bufnr))
    assert.is_true(vim.api.nvim_buf_is_valid(sess.modified_bufnr))

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

    local result, tabpage = create_test_diff_view(original, modified, left_path, right_path)

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
    local lines = { "line 1", "line 2", "line 3" }

    local left_path = get_temp_path("test_view_left_7.txt")
    local right_path = get_temp_path("test_view_right_7.txt")
    vim.fn.writefile(lines, left_path)
    vim.fn.writefile(lines, right_path)

    local result, tabpage
    local success = pcall(function()
      result, tabpage = create_test_diff_view(lines, lines, left_path, right_path)
    end)
    assert.is_true(success, "Should create view even with no changes")
    assert.is_not_nil(result, "view.create should return non-nil for identical files")
    -- Session exists and both panes show the shared content.
    vim.wait(2000, function() return lifecycle.get_session(tabpage) ~= nil end, 25)
    local sess = lifecycle.get_session(tabpage)
    assert.is_not_nil(sess)
    local orig = table.concat(vim.api.nvim_buf_get_lines(sess.original_bufnr, 0, -1, false), "\n")
    local mod = table.concat(vim.api.nvim_buf_get_lines(sess.modified_bufnr, 0, -1, false), "\n")
    assert.equal(orig, mod, "identical files must render identical content in both panes")
    assert.is_true(orig:find("line 1", 1, true) ~= nil, "expected content missing from original pane")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 8: Switching between tabs preserves diff view
  it("Diff view persists when switching tabs", function()
    local original = { "line 1" }
    local modified = { "line 2" }
    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_8.txt")
    local right_path = get_temp_path("test_view_right_8.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result, tabpage = create_test_diff_view(original, modified, left_path, right_path)

    local diff_tab = vim.api.nvim_get_current_tabpage()

    -- Create and switch to another tab
    vim.cmd("tabnew")
    vim.cmd("tabprevious")

    -- Should still be on diff tab
    local current_tab = vim.api.nvim_get_current_tabpage()
    assert.equal(diff_tab, current_tab, "Should be back on diff tab")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 9: Multiple diff views in different tabs
  it("Can create multiple diff views in different tabs", function()
    local tabs_before = vim.fn.tabpagenr("$")

    -- Create first diff
    local original1 = { "a" }
    local modified1 = { "b" }
    local left_path1 = get_temp_path("test_view_left_9a.txt")
    local right_path1 = get_temp_path("test_view_right_9a.txt")
    vim.fn.writefile(original1, left_path1)
    vim.fn.writefile(modified1, right_path1)

    local result1, tabpage1 = create_test_diff_view(original1, modified1, left_path1, right_path1)

    -- Create second diff
    local original2 = { "c" }
    local modified2 = { "d" }
    local left_path2 = get_temp_path("test_view_left_9b.txt")
    local right_path2 = get_temp_path("test_view_right_9b.txt")
    vim.fn.writefile(original2, left_path2)
    vim.fn.writefile(modified2, right_path2)

    local result2, tabpage2 = create_test_diff_view(original2, modified2, left_path2, right_path2)

    local tabs_after = vim.fn.tabpagenr("$")
    assert.equal(tabs_before + 2, tabs_after, "Should create 2 new tabs")

    vim.fn.delete(left_path1)
    vim.fn.delete(right_path1)
    vim.fn.delete(left_path2)
    vim.fn.delete(right_path2)
  end)

  -- Test 10: View handles single-line files
  it("Handles single-line files correctly", function()
    local original = { "single line" }
    local modified = { "different line" }
    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_10.txt")
    local right_path = get_temp_path("test_view_right_10.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local tabpage
    local success = pcall(function()
      _, tabpage = create_test_diff_view(original, modified, left_path, right_path)
    end)
    assert.is_true(success, "Should handle single-line files")

    -- The rendered content on each pane matches the source lines.
    vim.wait(2000, function() return lifecycle.get_session(tabpage) ~= nil end, 25)
    local sess = lifecycle.get_session(tabpage)
    assert.is_not_nil(sess)
    assert.equal("single line",
      table.concat(vim.api.nvim_buf_get_lines(sess.original_bufnr, 0, -1, false), "\n"))
    assert.equal("different line",
      table.concat(vim.api.nvim_buf_get_lines(sess.modified_bufnr, 0, -1, false), "\n"))

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 11: View handles files with special characters
  it("Handles files with special characters in content", function()
    local original = { "line with 'quotes'", 'line with "double quotes"' }
    local modified = { "line with $dollar", "line with `backtick`" }
    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_11.txt")
    local right_path = get_temp_path("test_view_right_11.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local tabpage
    local success = pcall(function()
      _, tabpage = create_test_diff_view(original, modified, left_path, right_path)
    end)
    assert.is_true(success, "Should handle special characters")

    -- Each special character survives round-tripping through the diff render
    -- into the pane buffers (regression guard for shell-escape / quote-eating).
    vim.wait(2000, function() return lifecycle.get_session(tabpage) ~= nil end, 25)
    local sess = lifecycle.get_session(tabpage)
    assert.is_not_nil(sess)
    local orig = table.concat(vim.api.nvim_buf_get_lines(sess.original_bufnr, 0, -1, false), "\n")
    local mod = table.concat(vim.api.nvim_buf_get_lines(sess.modified_bufnr, 0, -1, false), "\n")
    assert.is_true(orig:find("'quotes'", 1, true) ~= nil, "single quotes must survive")
    assert.is_true(orig:find('"double quotes"', 1, true) ~= nil, "double quotes must survive")
    assert.is_true(mod:find("$dollar", 1, true) ~= nil, "dollar sign must survive")
    assert.is_true(mod:find("`backtick`", 1, true) ~= nil, "backticks must survive")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 12: View creation doesn't affect other buffers
  it("View creation doesn't modify other open buffers", function()
    -- Create a buffer with content
    local other_buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, { "other content" })

    local original = { "line 1" }
    local modified = { "line 2" }
    local lines_diff = diff.compute_diff(original, modified)

    local left_path = get_temp_path("test_view_left_13.txt")
    local right_path = get_temp_path("test_view_right_13.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result, tabpage = create_test_diff_view(original, modified, left_path, right_path)

    -- Other buffer should be unchanged
    local other_lines = vim.api.nvim_buf_get_lines(other_buf, 0, -1, false)
    assert.are.same({ "other content" }, other_lines, "Other buffer should be unchanged")

    vim.api.nvim_buf_delete(other_buf, { force = true })
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

    local tabpage
    local success = pcall(function()
      _, tabpage = create_test_diff_view(original, modified, left_path, right_path)
    end)
    assert.is_true(success, "Should handle many hunks")

    -- The rendered diff carries at least as many hunks as we injected — the
    -- upstream diff engine can merge adjacent changes, so accept "many" (>= 10)
    -- rather than exactly 25.
    vim.wait(2000, function() return lifecycle.get_session(tabpage) ~= nil end, 25)
    local sess = lifecycle.get_session(tabpage)
    assert.is_not_nil(sess)
    assert.is_not_nil(sess.stored_diff_result)
    local changes = sess.stored_diff_result.changes or {}
    assert.is_true(#changes >= 10,
      "expected many change hunks in a 25-mod file; got " .. tostring(#changes))

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 15: Calling create multiple times in sequence
  it("Can call create multiple times without issues", function()
    for i = 1, 3 do
      local original = { "iteration " .. i }
      local modified = { "changed " .. i }
      local lines_diff = diff.compute_diff(original, modified)

      local left_path = get_temp_path("test_view_left_15_" .. i .. ".txt")
      local right_path = get_temp_path("test_view_right_15_" .. i .. ".txt")
      vim.fn.writefile(original, left_path)
      vim.fn.writefile(modified, right_path)

      local tabpage
      local success = pcall(function()
        _, tabpage = create_test_diff_view(original, modified, left_path, right_path)
      end)
      assert.is_true(success, "Iteration " .. i .. " should succeed")

      -- Each iteration must produce its OWN session (not silently reuse a stale
      -- one) — check that the session's content matches THIS iteration's input.
      vim.wait(2000, function() return lifecycle.get_session(tabpage) ~= nil end, 25)
      local sess = lifecycle.get_session(tabpage)
      assert.is_not_nil(sess, "iteration " .. i .. " should register its own session")
      local mod = table.concat(vim.api.nvim_buf_get_lines(sess.modified_bufnr, 0, -1, false), "\n")
      assert.is_true(mod:find("changed " .. i, 1, true) ~= nil,
        "iteration " .. i .. " modified pane should show 'changed " .. i .. "', got: " .. mod)

      vim.fn.delete(left_path)
      vim.fn.delete(right_path)
    end
  end)

  -- Test 16: Re-opening a diff whose file was deleted behind our back must stay
  -- quiet. Neovim timestamp-checks a buffer whenever it becomes visible, and
  -- both `:edit` and displaying an already-loaded buffer surface that as
  -- `E211: File ... no longer available` — a bare `pcall` does not suppress it,
  -- and on some platforms it aborts view construction outright.
  it("Does not report E211 when a diffed file is deleted behind the view", function()
    local original = { "line 1", "line 2" }
    local modified = { "line 1", "changed" }

    local left_path = get_temp_path("test_view_left_16.txt")
    local right_path = get_temp_path("test_view_right_16.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    -- First create loads both real files into buffers displayed in windows.
    create_test_diff_view(original, modified, left_path, right_path)
    vim.wait(200)

    -- Both files vanish (external `rm`, `git stash`, branch switch, ...).
    vim.fn.delete(left_path)
    vim.fn.delete(right_path)

    -- Second create finds those buffers by name and re-displays them.
    vim.cmd("messages clear")
    create_test_diff_view(original, modified, left_path, right_path)
    vim.wait(200)

    local messages = vim.fn.execute("messages")
    assert.is_nil(messages:find("E211", 1, true), "Re-displaying a loaded buffer for a deleted file should not report E211, got: " .. messages)
  end)

  -- Test 17: Same situation, but reached through the "no buffer found, load it"
  -- branch. A path that is spelled differently from the buffer's name (here an
  -- extra "." segment; on macOS the real trigger is /tmp being a symlink to
  -- /private/tmp) misses the by-name lookup, yet still resolves to the very
  -- same buffer once loaded.
  it("Does not report E211 when loading a deleted file whose buffer is already open", function()
    local original = { "line 1", "line 2" }
    local modified = { "line 1", "changed" }

    local left_path = get_temp_path("test_view_left_17.txt")
    local right_path = get_temp_path("test_view_right_17.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    create_test_diff_view(original, modified, left_path, right_path)
    vim.wait(200)

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)

    local sep = package.config:sub(1, 1)
    local function indirect(p)
      local dir, name = p:match("^(.*)[/\\]([^/\\]+)$")
      return dir .. sep .. "." .. sep .. name
    end

    vim.cmd("messages clear")
    create_test_diff_view(original, modified, indirect(left_path), indirect(right_path))
    vim.wait(200)

    local messages = vim.fn.execute("messages")
    assert.is_nil(messages:find("E211", 1, true), "Loading a deleted file that is already open should not report E211, got: " .. messages)
  end)
end)
