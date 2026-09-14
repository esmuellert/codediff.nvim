-- Test: inline diff mode in standalone mode
-- Verifies single-window inline layout with virtual line overlays

local view = require("codediff.ui.view")
local diff = require("codediff.core.diff")
local highlights = require("codediff.ui.highlights")
local lifecycle = require("codediff.ui.lifecycle")
local path = require("codediff.core.path")

-- Inline namespace (must match codediff.ui.inline)
local ns_inline = vim.api.nvim_create_namespace("codediff-inline")

-- Helper to get temp path (OS-aware)
local function get_temp_path(filename)
  local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local temp_dir = is_windows and (vim.fn.getenv("TEMP") or "C:\\Windows\\Temp") or "/tmp"
  local sep = is_windows and "\\" or "/"
  return temp_dir .. sep .. filename
end

-- Helper to create inline diff view
local function create_inline_view(original_lines, modified_lines, left_path, right_path)
  local session_config = {
    git_root = nil,
    original = path.make_ref(left_path, nil),
    modified = path.make_ref(right_path, nil),
    original_revision = nil,
    modified_revision = nil,
  }

  local result = view.create(session_config)
  local tabpage = vim.api.nvim_get_current_tabpage()
  return result, tabpage
end

-- Helper: collect extmarks and classify them
local function get_inline_extmarks(bufnr)
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns_inline, 0, -1, { details = true })
  local has_virt_lines = false
  local has_insert_hl = false

  for _, mark in ipairs(extmarks) do
    local details = mark[4]
    if details.virt_lines and #details.virt_lines > 0 then
      has_virt_lines = true
    end
    if details.hl_group and (details.hl_group == "CodeDiffLineInsert" or details.hl_group == "CodeDiffCharInsert") then
      has_insert_hl = true
    end
  end

  return {
    total = #extmarks,
    has_virt_lines = has_virt_lines,
    has_insert_hl = has_insert_hl,
    extmarks = extmarks,
  }
end

describe("Inline standalone view", function()
  before_each(function()
    -- Enable inline layout
    require("codediff").setup({ diff = { layout = "inline" } })
    highlights.setup()
  end)

  after_each(function()
    -- Close all extra tabs
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    -- Reset to default layout
    require("codediff").setup({ diff = { layout = "side-by-side" } })
  end)

  -- Test 1: Two real files — inline creates 1 window, session.layout == "inline"
  it("creates 1 window with inline layout and session.layout == 'inline'", function()
    local original = { "line 1", "line 2" }
    local modified = { "line 1", "line 3" }

    local left_path = get_temp_path("inline_t1_left.txt")
    local right_path = get_temp_path("inline_t1_right.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result, tabpage = create_inline_view(original, modified, left_path, right_path)

    -- Wait for async render
    vim.cmd("redraw")
    vim.wait(300)

    -- Inline mode: only 1 diff-content window per tab (not 2 like side-by-side)
    local wins = vim.api.nvim_tabpage_list_wins(tabpage)
    assert.equal(1, #wins, "Inline mode should have exactly 1 window")

    -- Session must have layout == "inline"
    local session = lifecycle.get_session(tabpage)
    assert.is_not_nil(session, "Session should exist")
    assert.equal("inline", session.layout, "Session layout should be 'inline'")

    -- Inline extmarks should be present on the modified buffer
    local mod_buf = result.modified_buf
    local info = get_inline_extmarks(mod_buf)
    assert.is_true(info.total > 0, "Should have inline extmarks for changed lines")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 2: Buffer content matches the modified file
  it("shows modified file content in the visible buffer", function()
    local original = { "alpha", "beta" }
    local modified = { "alpha", "gamma", "delta" }

    local left_path = get_temp_path("inline_t2_left.txt")
    local right_path = get_temp_path("inline_t2_right.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result, tabpage = create_inline_view(original, modified, left_path, right_path)
    vim.cmd("redraw")
    vim.wait(300)

    local buf_lines = vim.api.nvim_buf_get_lines(result.modified_buf, 0, -1, false)
    assert.are.same(modified, buf_lines, "Buffer should contain modified file content")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 3: Modification produces both virt_lines (deleted) and hl_group (inserted) extmarks
  it("produces virt_lines for deletions and hl_group for insertions on modification", function()
    local original = { "same", "old line", "same end" }
    local modified = { "same", "new line", "same end" }

    local left_path = get_temp_path("inline_t3_left.txt")
    local right_path = get_temp_path("inline_t3_right.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result, tabpage = create_inline_view(original, modified, left_path, right_path)
    vim.cmd("redraw")
    vim.wait(300)

    local info = get_inline_extmarks(result.modified_buf)
    assert.is_true(info.has_virt_lines, "Should have virt_lines for deleted original line")
    assert.is_true(info.has_insert_hl, "Should have insert highlight for new modified line")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 4: Identical files — no inline extmarks
  it("produces no inline extmarks when files are identical", function()
    local lines = { "identical 1", "identical 2", "identical 3" }

    local left_path = get_temp_path("inline_t4_left.txt")
    local right_path = get_temp_path("inline_t4_right.txt")
    vim.fn.writefile(lines, left_path)
    vim.fn.writefile(lines, right_path)

    local result, tabpage = create_inline_view(lines, lines, left_path, right_path)
    vim.cmd("redraw")
    vim.wait(300)

    local info = get_inline_extmarks(result.modified_buf)
    assert.equal(0, info.total, "Identical files should have no inline extmarks")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 5: Pure addition — insert highlights, no virt_lines
  it("shows insert highlights but no virt_lines for pure additions", function()
    local original = { "line 1", "line 2" }
    local modified = { "line 1", "line 2", "line 3", "line 4" }

    local left_path = get_temp_path("inline_t5_left.txt")
    local right_path = get_temp_path("inline_t5_right.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result, tabpage = create_inline_view(original, modified, left_path, right_path)
    vim.cmd("redraw")
    vim.wait(300)

    local info = get_inline_extmarks(result.modified_buf)
    assert.is_true(info.has_insert_hl, "Should have insert highlights for added lines")
    assert.is_false(info.has_virt_lines, "Pure addition should not have virt_lines")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 6: Pure deletion — virt_lines present, no insert highlights
  it("shows virt_lines but no insert highlights for pure deletions", function()
    local original = { "line 1", "line 2", "line 3", "line 4" }
    local modified = { "line 1", "line 2" }

    local left_path = get_temp_path("inline_t6_left.txt")
    local right_path = get_temp_path("inline_t6_right.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result, tabpage = create_inline_view(original, modified, left_path, right_path)
    vim.cmd("redraw")
    vim.wait(300)

    local info = get_inline_extmarks(result.modified_buf)
    assert.is_true(info.has_virt_lines, "Should have virt_lines for deleted lines")
    assert.is_false(info.has_insert_hl, "Pure deletion should not have insert highlights")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 7: Large files handled efficiently
  it("Handles large files efficiently", function()
    local original = {}
    local modified = {}
    for i = 1, 500 do
      table.insert(original, "line " .. i)
      table.insert(modified, "line " .. i)
    end
    -- Change a few lines
    modified[100] = "CHANGED 100"
    modified[250] = "CHANGED 250"
    modified[400] = "CHANGED 400"

    local left_path = get_temp_path("inline_t7_left.txt")
    local right_path = get_temp_path("inline_t7_right.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local start_time = vim.fn.reltime()
    local result, tabpage = create_inline_view(original, modified, left_path, right_path)
    vim.cmd("redraw")
    vim.wait(300)
    local elapsed_ms = vim.fn.reltimefloat(vim.fn.reltime(start_time)) * 1000

    local session = lifecycle.get_session(tabpage)
    assert.is_truthy(session, "Session should exist for large file")
    assert.is_truthy(session.stored_diff_result, "Diff result should exist")
    assert.are.equal(3, #session.stored_diff_result.changes, "Should detect 3 changes")

    -- Should complete in reasonable time
    assert.is_true(elapsed_ms < 5000, "View creation took " .. elapsed_ms .. "ms, should be under 5s")
    print("View creation took " .. string.format("%.2f", elapsed_ms) .. " ms")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 8: Diff view persists when switching tabs
  it("Diff view persists when switching tabs", function()
    local original = {"line 1", "line 2"}
    local modified = {"line 1", "CHANGED"}

    local left_path = get_temp_path("inline_t8_left.txt")
    local right_path = get_temp_path("inline_t8_right.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result, tabpage = create_inline_view(original, modified, left_path, right_path)
    vim.cmd("redraw")
    vim.wait(300)

    -- Switch to a new tab and back
    vim.cmd("tabnew")
    vim.cmd("tabprev")

    local session = lifecycle.get_session(tabpage)
    assert.is_truthy(session, "Session should persist after tab switch")
    assert.are.equal("inline", session.layout, "Layout should still be inline")

    -- Close the extra tab
    vim.cmd("tabnext")
    vim.cmd("tabclose")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 9: Can create multiple inline diff views in different tabs
  it("Can create multiple inline diff views in different tabs", function()
    local left1 = get_temp_path("inline_t9_left1.txt")
    local right1 = get_temp_path("inline_t9_right1.txt")
    local left2 = get_temp_path("inline_t9_left2.txt")
    local right2 = get_temp_path("inline_t9_right2.txt")

    vim.fn.writefile({"aaa"}, left1)
    vim.fn.writefile({"bbb"}, right1)
    vim.fn.writefile({"xxx"}, left2)
    vim.fn.writefile({"yyy"}, right2)

    local _, tab1 = create_inline_view({"aaa"}, {"bbb"}, left1, right1)
    vim.cmd("redraw")
    vim.wait(200)

    local _, tab2 = create_inline_view({"xxx"}, {"yyy"}, left2, right2)
    vim.cmd("redraw")
    vim.wait(200)

    local s1 = lifecycle.get_session(tab1)
    local s2 = lifecycle.get_session(tab2)

    assert.is_truthy(s1, "First session should exist")
    assert.is_truthy(s2, "Second session should exist")
    assert.are.equal("inline", s1.layout)
    assert.are.equal("inline", s2.layout)
    assert.are_not.equal(tab1, tab2, "Should be different tabs")

    vim.fn.delete(left1)
    vim.fn.delete(right1)
    vim.fn.delete(left2)
    vim.fn.delete(right2)
  end)

  -- Test 10: Handles single-line files correctly
  it("Handles single-line files correctly", function()
    local original = {"only line"}
    local modified = {"changed line"}

    local left_path = get_temp_path("inline_t10_left.txt")
    local right_path = get_temp_path("inline_t10_right.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result, tabpage = create_inline_view(original, modified, left_path, right_path)
    vim.cmd("redraw")
    vim.wait(300)

    local session = lifecycle.get_session(tabpage)
    assert.is_truthy(session, "Session should exist")
    assert.is_truthy(session.stored_diff_result, "Diff should compute")

    local info = get_inline_extmarks(result.modified_buf)
    assert.is_true(info.has_virt_lines or info.has_insert_hl, "Should have some decoration for changed line")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 11: Handles files with special characters in content
  it("Handles files with special characters in content", function()
    local original = {"hello 世界", "tab\there", "émojis 🎉"}
    local modified = {"hello 世界", "tab\tCHANGED", "émojis 🎉"}

    local left_path = get_temp_path("inline_t11_left.txt")
    local right_path = get_temp_path("inline_t11_right.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result, tabpage = create_inline_view(original, modified, left_path, right_path)
    vim.cmd("redraw")
    vim.wait(300)

    local session = lifecycle.get_session(tabpage)
    assert.is_truthy(session, "Session should exist with special chars")
    assert.is_truthy(session.stored_diff_result, "Diff should compute")
    assert.are.equal(1, #session.stored_diff_result.changes, "Should detect 1 change")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 12: View creation doesn't modify other open buffers
  it("View creation doesn't modify other open buffers", function()
    -- Create a buffer with known content before diff
    local pre_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(pre_buf, 0, -1, false, {"pre-existing", "content"})
    local pre_tick = vim.api.nvim_buf_get_changedtick(pre_buf)

    local original = {"line 1"}
    local modified = {"CHANGED"}

    local left_path = get_temp_path("inline_t12_left.txt")
    local right_path = get_temp_path("inline_t12_right.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    create_inline_view(original, modified, left_path, right_path)
    vim.cmd("redraw")
    vim.wait(300)

    -- Pre-existing buffer should be untouched
    local post_lines = vim.api.nvim_buf_get_lines(pre_buf, 0, -1, false)
    assert.are.same({"pre-existing", "content"}, post_lines, "Pre-existing buffer should be unchanged")
    assert.are.equal(pre_tick, vim.api.nvim_buf_get_changedtick(pre_buf), "Changedtick should be unchanged")

    pcall(vim.api.nvim_buf_delete, pre_buf, { force = true })
    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 13: Handles files with many change hunks
  it("Handles files with many change hunks", function()
    local original = {}
    local modified = {}
    for i = 1, 20 do
      table.insert(original, "line " .. i)
      if i % 2 == 0 then
        table.insert(modified, "CHANGED " .. i)
      else
        table.insert(modified, "line " .. i)
      end
    end

    local left_path = get_temp_path("inline_t13_left.txt")
    local right_path = get_temp_path("inline_t13_right.txt")
    vim.fn.writefile(original, left_path)
    vim.fn.writefile(modified, right_path)

    local result, tabpage = create_inline_view(original, modified, left_path, right_path)
    vim.cmd("redraw")
    vim.wait(300)

    local session = lifecycle.get_session(tabpage)
    assert.is_truthy(session, "Session should exist")
    assert.is_truthy(session.stored_diff_result, "Diff should compute")
    assert.is_true(#session.stored_diff_result.changes >= 5, "Should have multiple hunks, got " .. #session.stored_diff_result.changes)

    local info = get_inline_extmarks(result.modified_buf)
    assert.is_true(info.has_virt_lines, "Should have virt_lines for changed lines")
    assert.is_true(info.has_insert_hl, "Should have insert highlights for changed lines")

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Test 14: Can call create multiple times without issues
  it("Can call create multiple times without issues", function()
    local left_path = get_temp_path("inline_t14_left.txt")
    local right_path = get_temp_path("inline_t14_right.txt")

    for i = 1, 3 do
      vim.fn.writefile({"original " .. i}, left_path)
      vim.fn.writefile({"modified " .. i}, right_path)

      local result, tabpage = create_inline_view({"original " .. i}, {"modified " .. i}, left_path, right_path)
      vim.cmd("redraw")
      vim.wait(200)

      local session = lifecycle.get_session(tabpage)
      assert.is_truthy(session, "Session should exist on iteration " .. i)
    end

    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)
end)
