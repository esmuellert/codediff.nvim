-- Test: ui/view/inline_history_spec.lua - Inline diff view with history-like configurations
-- Validates the rendering path that history mode uses when layout = "inline"

local view = require("codediff.ui.view")
local inline_view = require("codediff.ui.view.inline_view")
local inline = require("codediff.ui.inline")
local diff = require("codediff.core.diff")
local lifecycle = require("codediff.ui.lifecycle")
local highlights = require("codediff.ui.highlights")
local test_helpers = require("tests.support")
local path = require("codediff.core.path")

-- Helper to get OS-appropriate temp path
local function get_temp_path(filename)
  return test_helpers.get_temp_path(filename)
end

describe("Inline diff with history-like configurations", function()
  before_each(function()
    require("codediff").setup({ diff = { layout = "inline" } })
    highlights.setup()
  end)

  after_each(function()
    -- Clean up all sessions
    pcall(lifecycle.cleanup_all)
    -- Close all extra tabs
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    -- Reset config to defaults
    require("codediff").setup({})
  end)

  -- Test 1: History placeholder creates inline session
  -- When the panel is history with data, inline_view.create() should produce
  -- a placeholder session marked with layout="inline".
  it("history placeholder creates an inline session", function()
    local session_config = {
      panel = {
        name = "history",
        data = {
          commits = {},
          range = "HEAD",
          file_path = "test.txt",
        },
      },
      git_root = "/tmp/fakerepo",
      original = path.make_ref("", "/tmp/fakerepo"),
      modified = path.make_ref("", "/tmp/fakerepo"),
      original_revision = nil,
      modified_revision = nil,
    }

    local result = inline_view.create(session_config)

    vim.cmd("redraw")
    vim.wait(100)

    local tabpage = vim.api.nvim_get_current_tabpage()
    local session = lifecycle.get_session(tabpage)

    assert.is_not_nil(session, "Session should be created for history placeholder")
    assert.equals("inline", session.layout, "Session layout should be 'inline'")
    assert.equals("history", session.panel and session.panel.name, "Session panel should be 'history'")
    assert.is_not_nil(result, "create() should return a result table")
    assert.is_not_nil(result.modified_buf, "Result should include modified_buf")
    assert.is_not_nil(result.original_buf, "Result should include original_buf")
    assert.is_not_nil(result.modified_win, "Result should include modified_win")

    -- Placeholder should have valid buffers attached
    assert.is_true(vim.api.nvim_buf_is_valid(result.modified_buf), "modified_buf should be valid")
    assert.is_true(vim.api.nvim_buf_is_valid(result.original_buf), "original_buf should be valid")
    assert.is_true(vim.api.nvim_win_is_valid(result.modified_win), "modified_win should be valid")
  end)

  -- Test 2: Two virtual revisions render inline extmarks
  -- Simulates history's update() rendering path: both files are "virtual" content
  -- (representing commit^ vs commit). We write two temp files with different content,
  -- create an inline view, and verify inline extmarks are present.
  it("two virtual revisions render inline extmarks", function()
    local original_lines = { "line 1", "line 2", "line 3" }
    local modified_lines = { "line 1", "line 2 changed", "line 3", "line 4 added" }

    local left_path = get_temp_path("inline_hist_left_2.txt")
    local right_path = get_temp_path("inline_hist_right_2.txt")
    vim.fn.writefile(original_lines, left_path)
    vim.fn.writefile(modified_lines, right_path)

    local session_config = {
      git_root = nil,
      original = path.make_ref(left_path, nil),
      modified = path.make_ref(right_path, nil),
      original_revision = nil,
      modified_revision = nil,
    }

    local result = inline_view.create(session_config)

    vim.cmd("redraw")
    vim.wait(200)

    local tabpage = vim.api.nvim_get_current_tabpage()
    local session = lifecycle.get_session(tabpage)

    assert.is_not_nil(session, "Session should be created")
    assert.equals("inline", session.layout, "Layout should be 'inline'")

    -- The modified buffer should have inline diff extmarks
    local mod_buf = result.modified_buf
    assert.is_true(vim.api.nvim_buf_is_valid(mod_buf), "modified_buf should be valid")

    local marks = vim.api.nvim_buf_get_extmarks(mod_buf, inline.ns_inline, 0, -1, { details = true })

    -- Should have extmarks for the changes (insert highlights, virtual lines for deletes)
    local has_insert_hl = false
    local has_virt_lines = false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.hl_group == "CodeDiffLineInsert" then
        has_insert_hl = true
      end
      if details.virt_lines and #details.virt_lines > 0 then
        has_virt_lines = true
      end
    end

    -- We expect at least insert highlights for the changed/added lines
    assert.is_true(has_insert_hl, "Should have CodeDiffLineInsert extmarks for changed lines")
    -- The modification of "line 2" -> "line 2 changed" should produce virtual lines showing the old text
    assert.is_true(has_virt_lines, "Should have virtual lines for deleted/modified original text")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 3: show_single_file for virtual content
  -- Verifies show_single_file() works without error and updates session state.
  -- We create an inline view first (so a session exists), then call show_single_file
  -- with a real temp file, simulating a deleted/added file in history.
  it("show_single_file updates session state correctly", function()
    local original_lines = { "aaa", "bbb" }
    local modified_lines = { "aaa", "ccc" }

    local left_path = get_temp_path("inline_hist_left_3.txt")
    local right_path = get_temp_path("inline_hist_right_3.txt")
    vim.fn.writefile(original_lines, left_path)
    vim.fn.writefile(modified_lines, right_path)

    -- First create a normal inline view to establish a session
    local session_config = {
      git_root = nil,
      original = path.make_ref(left_path, nil),
      modified = path.make_ref(right_path, nil),
      original_revision = nil,
      modified_revision = nil,
    }

    local result = inline_view.create(session_config)

    vim.cmd("redraw")
    vim.wait(200)

    local tabpage = vim.api.nvim_get_current_tabpage()
    local session_before = lifecycle.get_session(tabpage)
    assert.is_not_nil(session_before, "Session should exist before show_single_file")

    -- Now write a separate "single" file to display
    local single_path = get_temp_path("inline_hist_single_3.txt")
    vim.fn.writefile({ "single file content", "second line" }, single_path)

    -- Call show_single_file — simulates displaying a deleted/added file in history
    local success = pcall(function()
      inline_view.show_single_file(tabpage, single_path, {})
    end)

    assert.is_true(success, "show_single_file should not error")

    vim.cmd("redraw")
    vim.wait(100)

    -- Session state should be updated
    local session_after = lifecycle.get_session(tabpage)
    assert.is_not_nil(session_after, "Session should still exist after show_single_file")

    -- Path should be updated to the single file
    local _, modified_ref = lifecycle.get_paths(tabpage)
    assert.equals(path.make_ref(single_path, nil).absolute, modified_ref.absolute, "Modified path should be updated to single file path")

    -- Original path should be empty (no comparison side)
    local original_ref, _ = lifecycle.get_paths(tabpage)
    assert.is_true(path.is_empty(original_ref), "Original path should be empty for single file view")

    -- The modified buffer should now show the single file content
    local _, mod_buf = lifecycle.get_buffers(tabpage)
    assert.is_true(vim.api.nvim_buf_is_valid(mod_buf), "Modified buffer should be valid")
    local buf_lines = vim.api.nvim_buf_get_lines(mod_buf, 0, -1, false)
    assert.are.same({ "single file content", "second line" }, buf_lines, "Modified buffer should contain single file content")

    -- Inline extmarks should be cleared (no diff decorations for single file)
    local marks = vim.api.nvim_buf_get_extmarks(mod_buf, inline.ns_inline, 0, -1, {})
    assert.equals(0, #marks, "Single file view should have no inline diff extmarks")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
    vim.fn.delete(single_path)
  end)

  -- Test 4: Session layout persists through update
  -- Creates an inline view, verifies layout="inline", then calls view.update()
  -- with new file paths and verifies layout is still "inline" after update.
  it("session layout persists through update", function()
    local original_lines = { "alpha", "beta" }
    local modified_lines = { "alpha", "gamma" }

    local left_path = get_temp_path("inline_hist_left_4.txt")
    local right_path = get_temp_path("inline_hist_right_4.txt")
    vim.fn.writefile(original_lines, left_path)
    vim.fn.writefile(modified_lines, right_path)

    -- Create initial inline view
    local session_config = {
      git_root = nil,
      original = path.make_ref(left_path, nil),
      modified = path.make_ref(right_path, nil),
      original_revision = nil,
      modified_revision = nil,
    }

    inline_view.create(session_config)

    vim.cmd("redraw")
    vim.wait(200)

    local tabpage = vim.api.nvim_get_current_tabpage()
    local session = lifecycle.get_session(tabpage)
    assert.is_not_nil(session, "Session should exist")
    assert.equals("inline", session.layout, "Initial layout should be 'inline'")

    -- Write new files for the update
    local new_original_lines = { "one", "two", "three" }
    local new_modified_lines = { "one", "TWO", "three", "four" }
    local new_left_path = get_temp_path("inline_hist_left_4b.txt")
    local new_right_path = get_temp_path("inline_hist_right_4b.txt")
    vim.fn.writefile(new_original_lines, new_left_path)
    vim.fn.writefile(new_modified_lines, new_right_path)

    -- Update the view with new files (using the view router which checks session.layout)
    local update_config = {
      git_root = nil,
      original = path.make_ref(new_left_path, nil),
      modified = path.make_ref(new_right_path, nil),
      original_revision = nil,
      modified_revision = nil,
    }

    local update_ok = view.update(tabpage, update_config, true)
    assert.is_true(update_ok, "view.update() should succeed")

    vim.cmd("redraw")
    vim.wait(200)

    -- Layout should still be "inline" after update
    local session_after = lifecycle.get_session(tabpage)
    assert.is_not_nil(session_after, "Session should still exist after update")
    assert.equals("inline", session_after.layout, "Layout should remain 'inline' after update")

    -- The updated buffer should have new inline extmarks for the changes
    local _, mod_buf = lifecycle.get_buffers(tabpage)
    if mod_buf and vim.api.nvim_buf_is_valid(mod_buf) then
      local marks = vim.api.nvim_buf_get_extmarks(mod_buf, inline.ns_inline, 0, -1, { details = true })
      local has_insert_hl = false
      for _, mark in ipairs(marks) do
        local details = mark[4]
        if details.hl_group == "CodeDiffLineInsert" then
          has_insert_hl = true
          break
        end
      end
      assert.is_true(has_insert_hl, "Updated view should have inline diff extmarks for new changes")
    end

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
    vim.fn.delete(new_left_path)
    vim.fn.delete(new_right_path)
  end)
end)
