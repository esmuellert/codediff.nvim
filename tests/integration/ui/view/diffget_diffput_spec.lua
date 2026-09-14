-- Test: diffget/diffput (do/dp) functionality
-- Tests for vimdiff-style change transfer between buffers

local view = require("codediff.ui.view")
local diff = require('codediff.core.diff')
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

-- Helper to create diff view and return buffers/windows
local function create_test_diff_view(original_lines, modified_lines, left_path, right_path)
  vim.fn.writefile(original_lines, left_path)
  vim.fn.writefile(modified_lines, right_path)

  local session_config = {
    git_root = nil,
    original = path.make_ref(left_path, nil),
    modified = path.make_ref(right_path, nil),
    original_revision = nil,
    modified_revision = nil,
  }

  view.create(session_config)

  -- Wait for view setup
  vim.cmd('redraw')
  vim.wait(200)

  local tabpage = vim.api.nvim_get_current_tabpage()
  local wins = vim.api.nvim_tabpage_list_wins(tabpage)

  -- Find which window has which buffer by checking buffer names.
  -- Normalize paths so Windows-style backslashes match Neovim's forward-slash
  -- buffer names: vim.api.nvim_buf_get_name() returns forward-slash paths on
  -- recent Neovim versions regardless of how the file was opened, while
  -- left_path/right_path may contain backslashes on Windows.
  local norm_left = vim.fs.normalize(left_path)
  local norm_right = vim.fs.normalize(right_path)
  local original_win, modified_win, original_bufnr, modified_bufnr
  for _, w in ipairs(wins) do
    local buf = vim.api.nvim_win_get_buf(w)
    local name = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
    if name:find(norm_left, 1, true) then
      original_win = w
      original_bufnr = buf
    elseif name:find(norm_right, 1, true) then
      modified_win = w
      modified_bufnr = buf
    end
  end

  return {
    tabpage = tabpage,
    original_bufnr = original_bufnr,
    modified_bufnr = modified_bufnr,
    original_win = original_win,
    modified_win = modified_win,
    left_path = left_path,
    right_path = right_path,
  }
end

describe("Diffget/Diffput", function()
  before_each(function()
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    highlights.setup()
  end)

  after_each(function()
    -- Close all extra tabs
    while vim.fn.tabpagenr('$') > 1 do
      vim.cmd('tabclose')
    end
  end)

  -- Test 1: diffget obtains change from modified to original buffer
  it("diffget obtains hunk from modified buffer to original buffer", function()
    local original = {"line 1", "line 2", "line 3"}
    local modified = {"line 1", "CHANGED", "line 3"}

    local left_path = get_temp_path("test_diffget_left_1.txt")
    local right_path = get_temp_path("test_diffget_right_1.txt")

    local ctx = create_test_diff_view(original, modified, left_path, right_path)

    -- Verify initial state
    local orig_lines = vim.api.nvim_buf_get_lines(ctx.original_bufnr, 0, -1, false)
    assert.are.same({"line 1", "line 2", "line 3"}, orig_lines)

    -- Move to original window and position cursor on the hunk (line 2)
    vim.api.nvim_set_current_win(ctx.original_win)
    vim.api.nvim_win_set_cursor(ctx.original_win, {2, 0})

    -- Simulate diffget by calling the keymap action
    vim.cmd('normal do')
    vim.wait(100)

    -- After diffget, original buffer should have the modified content
    local new_orig_lines = vim.api.nvim_buf_get_lines(ctx.original_bufnr, 0, -1, false)
    assert.are.same({"line 1", "CHANGED", "line 3"}, new_orig_lines)

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 2: diffput sends change from original to modified buffer
  it("diffput sends hunk from original buffer to modified buffer", function()
    local original = {"line 1", "ORIGINAL", "line 3"}
    local modified = {"line 1", "line 2", "line 3"}

    local left_path = get_temp_path("test_diffput_left_2.txt")
    local right_path = get_temp_path("test_diffput_right_2.txt")

    local ctx = create_test_diff_view(original, modified, left_path, right_path)

    -- Verify initial state
    local mod_lines = vim.api.nvim_buf_get_lines(ctx.modified_bufnr, 0, -1, false)
    assert.are.same({"line 1", "line 2", "line 3"}, mod_lines)

    -- Move to original window and position cursor on the hunk (line 2)
    vim.api.nvim_set_current_win(ctx.original_win)
    vim.api.nvim_win_set_cursor(ctx.original_win, {2, 0})

    -- Simulate diffput
    vim.cmd('normal dp')
    vim.wait(100)

    -- After diffput, modified buffer should have the original content
    local new_mod_lines = vim.api.nvim_buf_get_lines(ctx.modified_bufnr, 0, -1, false)
    assert.are.same({"line 1", "ORIGINAL", "line 3"}, new_mod_lines)

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 3: diffget from modified window gets from original
  it("diffget from modified window obtains from original buffer", function()
    local original = {"line 1", "FROM_ORIGINAL", "line 3"}
    local modified = {"line 1", "line 2", "line 3"}

    local left_path = get_temp_path("test_diffget_left_3.txt")
    local right_path = get_temp_path("test_diffget_right_3.txt")

    local ctx = create_test_diff_view(original, modified, left_path, right_path)

    -- Move to modified window and position cursor on the hunk
    vim.api.nvim_set_current_win(ctx.modified_win)
    vim.api.nvim_win_set_cursor(ctx.modified_win, {2, 0})

    -- Simulate diffget from modified side
    vim.cmd('normal do')
    vim.wait(100)

    -- After diffget, modified buffer should have content from original
    local new_mod_lines = vim.api.nvim_buf_get_lines(ctx.modified_bufnr, 0, -1, false)
    assert.are.same({"line 1", "FROM_ORIGINAL", "line 3"}, new_mod_lines)

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 4: diffput from modified window sends to original
  it("diffput from modified window sends to original buffer", function()
    local original = {"line 1", "line 2", "line 3"}
    local modified = {"line 1", "FROM_MODIFIED", "line 3"}

    local left_path = get_temp_path("test_diffput_left_4.txt")
    local right_path = get_temp_path("test_diffput_right_4.txt")

    local ctx = create_test_diff_view(original, modified, left_path, right_path)

    -- Move to modified window and position cursor on the hunk
    vim.api.nvim_set_current_win(ctx.modified_win)
    vim.api.nvim_win_set_cursor(ctx.modified_win, {2, 0})

    -- Simulate diffput from modified side
    vim.cmd('normal dp')
    vim.wait(100)

    -- After diffput, original buffer should have content from modified
    local new_orig_lines = vim.api.nvim_buf_get_lines(ctx.original_bufnr, 0, -1, false)
    assert.are.same({"line 1", "FROM_MODIFIED", "line 3"}, new_orig_lines)

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 5: Multi-line hunk transfer
  it("transfers multi-line hunks correctly", function()
    local original = {"line 1", "old A", "old B", "old C", "line 5"}
    local modified = {"line 1", "new A", "new B", "line 5"}

    local left_path = get_temp_path("test_multiline_left_5.txt")
    local right_path = get_temp_path("test_multiline_right_5.txt")

    local ctx = create_test_diff_view(original, modified, left_path, right_path)

    -- Move to original window and position cursor on the hunk
    vim.api.nvim_set_current_win(ctx.original_win)
    vim.api.nvim_win_set_cursor(ctx.original_win, {2, 0})

    -- Get change from modified (which has fewer lines)
    vim.cmd('normal do')
    vim.wait(100)

    -- Original should now match modified's hunk
    local new_orig_lines = vim.api.nvim_buf_get_lines(ctx.original_bufnr, 0, -1, false)
    assert.are.same({"line 1", "new A", "new B", "line 5"}, new_orig_lines)

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 6: Insertion hunk (empty range on one side)
  it("handles insertion hunks correctly", function()
    local original = {"line 1", "line 3"}
    local modified = {"line 1", "inserted", "line 3"}

    local left_path = get_temp_path("test_insert_left_6.txt")
    local right_path = get_temp_path("test_insert_right_6.txt")

    local ctx = create_test_diff_view(original, modified, left_path, right_path)

    -- Move to modified window on the inserted line
    vim.api.nvim_set_current_win(ctx.modified_win)
    vim.api.nvim_win_set_cursor(ctx.modified_win, {2, 0})

    -- Put the insertion to original
    vim.cmd('normal dp')
    vim.wait(100)

    -- Original should now have the inserted line
    local new_orig_lines = vim.api.nvim_buf_get_lines(ctx.original_bufnr, 0, -1, false)
    assert.are.same({"line 1", "inserted", "line 3"}, new_orig_lines)

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 7: Deletion hunk (empty range on one side)
  it("handles deletion hunks correctly", function()
    local original = {"line 1", "to_delete", "line 3"}
    local modified = {"line 1", "line 3"}

    local left_path = get_temp_path("test_delete_left_7.txt")
    local right_path = get_temp_path("test_delete_right_7.txt")

    local ctx = create_test_diff_view(original, modified, left_path, right_path)

    -- Move to original window on the line to delete
    vim.api.nvim_set_current_win(ctx.original_win)
    vim.api.nvim_win_set_cursor(ctx.original_win, {2, 0})

    -- Get the deletion from modified (effectively delete)
    vim.cmd('normal do')
    vim.wait(100)

    -- Original should now have the line deleted
    local new_orig_lines = vim.api.nvim_buf_get_lines(ctx.original_bufnr, 0, -1, false)
    assert.are.same({"line 1", "line 3"}, new_orig_lines)

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 8: Multiple hunks - only transfers current hunk
  it("only transfers the hunk at cursor position", function()
    local original = {"hunk1_orig", "same", "hunk2_orig"}
    local modified = {"hunk1_mod", "same", "hunk2_mod"}

    local left_path = get_temp_path("test_multi_hunk_left_8.txt")
    local right_path = get_temp_path("test_multi_hunk_right_8.txt")

    local ctx = create_test_diff_view(original, modified, left_path, right_path)

    -- Move to original window, position on first hunk
    vim.api.nvim_set_current_win(ctx.original_win)
    vim.api.nvim_win_set_cursor(ctx.original_win, {1, 0})

    -- Get only first hunk
    vim.cmd('normal do')
    vim.wait(100)

    -- Only first line should change, second hunk unchanged
    local new_orig_lines = vim.api.nvim_buf_get_lines(ctx.original_bufnr, 0, -1, false)
    assert.are.same({"hunk1_mod", "same", "hunk2_orig"}, new_orig_lines)

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)
end)
