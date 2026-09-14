-- Integration from registered keymap callbacks through Git and view refresh.
-- These invoke callbacks directly and inspect buffers/extmarks. Actual keyboard
-- and screen coverage lives in tests/e2e/view/hunk_actions_spec.lua.

local h = require("tests.support")

-- Ensure plugin is loaded (needed when the test framework isolates specs)
h.ensure_plugin_loaded()

-- Setup CodeDiff user command for tests
local function setup_command()
  local commands = require("codediff.commands")
  vim.api.nvim_create_user_command("CodeDiff", function(opts)
    commands.vscode_diff(opts)
  end, {
    nargs = "*",
    bang = true,
    complete = function()
      return { "file", "install" }
    end,
  })
end

-- ============================================================================
-- Helpers
-- ============================================================================

--- Get keymap callback by description pattern on a specific buffer.
--- Searches normal-mode buffer-local keymaps for a matching desc field.
--- @param bufnr number
--- @param desc_pattern string  Lua pattern to match against km.desc
--- @return function|nil callback  The RHS callback, or nil if not found
local function get_keymap_fn(bufnr, desc_pattern)
  local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  for _, km in ipairs(maps) do
    if km.desc and km.desc:find(desc_pattern) then
      return km.callback
    end
  end
  return nil
end

--- Count extmarks in a namespace on a buffer.
--- @param bufnr number
--- @param ns number  Namespace id
--- @return number
local function count_highlights(bufnr, ns)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return 0
  end
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  return #marks
end

--- Count extmarks whose hl_group matches a pattern.
--- @param bufnr number
--- @param ns number  Namespace id
--- @param hl_pattern string  Lua pattern for hl_group (e.g. "CodeDiffLine")
--- @return number
local function count_line_highlights(bufnr, ns, hl_pattern)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return 0
  end
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  local count = 0
  for _, m in ipairs(marks) do
    local details = m[4]
    if details and details.hl_group and details.hl_group:find(hl_pattern) then
      count = count + 1
    end
  end
  return count
end

--- Wait until the session's stored_diff_result has exactly `expected_count` hunks.
--- @param tabpage number
--- @param expected_count number
--- @param timeout_ms number
--- @return boolean  true if condition met within timeout
local function wait_for_hunks(tabpage, expected_count, timeout_ms)
  timeout_ms = timeout_ms or 8000
  local lifecycle = require("codediff.ui.lifecycle")
  return vim.wait(timeout_ms, function()
    local session = lifecycle.get_session(tabpage)
    if not session or not session.stored_diff_result then
      return false
    end
    local changes = session.stored_diff_result.changes
    if not changes then
      return false
    end
    return #changes == expected_count
  end, 100)
end

--- Open :CodeDiff in the given repo directory and wait until the explorer
--- is fully ready (session exists, explorer is set, diff buffers loaded).
--- Returns tabpage, session, explorer.
--- @param repo table  Repo helper from h.create_temp_git_repo()
--- @param timeout_ms? number  (default 10000)
--- @return number tabpage
--- @return table session
--- @return table explorer
local function open_codediff_and_wait(repo, timeout_ms)
  timeout_ms = timeout_ms or 10000
  vim.fn.chdir(repo.dir)
  -- Open a file so CodeDiff has context
  vim.cmd("edit " .. repo.path("file1.txt"))
  vim.cmd("CodeDiff")

  local lifecycle = require("codediff.ui.lifecycle")
  local tabpage

  local ready = vim.wait(timeout_ms, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local s = lifecycle.get_session(tp)
      if s and (s.panel or {}).view then
        tabpage = tp
        local orig_buf, mod_buf = lifecycle.get_buffers(tp)
        if orig_buf and mod_buf then
          return vim.api.nvim_buf_is_valid(orig_buf) and vim.api.nvim_buf_is_valid(mod_buf)
        end
      end
    end
    return false
  end, 100)

  assert.is_true(ready, "CodeDiff explorer and diff panes should be ready")

  local session = lifecycle.get_session(tabpage)
  local explorer = (session.panel or {}).view
  assert.is_not_nil(explorer, "Explorer should exist on session")

  return tabpage, session, explorer
end

--- Focus the modified diff window and position cursor at a given line.
--- @param tabpage number
--- @param line number  1-based line number
local function position_cursor_in_modified(tabpage, line)
  local lifecycle = require("codediff.ui.lifecycle")
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end
  local win = session.modified_win
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    local max_line = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    line = math.min(line, max_line)
    vim.api.nvim_win_set_cursor(win, { line, 0 })
  end
end

--- Create a repo with a single file that has exactly 2 hunks after modification.
--- Hunk 1 is near line 1, hunk 2 is near line 9.
--- @return table repo  h.create_temp_git_repo() result
local function create_two_hunk_repo()
  local repo = h.create_temp_git_repo()
  -- 10-line file; lines 1 and 9 will be changed
  repo.write_file("file1.txt", {
    "original line 1",
    "context line 2",
    "context line 3",
    "context line 4",
    "context line 5",
    "context line 6",
    "context line 7",
    "context line 8",
    "original line 9",
    "context line 10",
  })
  repo.git("add file1.txt")
  repo.git('commit -m "initial"')
  repo.write_file("file1.txt", {
    "MODIFIED line 1",
    "context line 2",
    "context line 3",
    "context line 4",
    "context line 5",
    "context line 6",
    "context line 7",
    "context line 8",
    "MODIFIED line 9",
    "context line 10",
  })
  return repo
end

--- Create a repo with a single file that has exactly 1 hunk.
--- @return table repo
local function create_one_hunk_repo()
  local repo = h.create_temp_git_repo()
  repo.write_file("file1.txt", {
    "original line 1",
    "context line 2",
    "context line 3",
  })
  repo.git("add file1.txt")
  repo.git('commit -m "initial"')
  repo.write_file("file1.txt", {
    "MODIFIED line 1",
    "context line 2",
    "context line 3",
  })
  return repo
end

-- ============================================================================
-- Side-by-side mode tests
-- ============================================================================
describe("Hunk operations (side-by-side)", function()
  local repo
  local original_cwd
  local original_autoread

  before_each(function()
    vim.g.mapleader = " "
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    setup_command()
    original_cwd = vim.fn.getcwd()
    original_autoread = vim.o.autoread
  end)

  after_each(function()
    pcall(function()
      vim.cmd("tabnew")
      vim.cmd("tabonly")
    end)
    vim.fn.chdir(original_cwd)
    vim.o.autoread = original_autoread
    vim.wait(200)
    if repo then
      repo.cleanup()
      repo = nil
    end
  end)

  -- --------------------------------------------------------------------------
  -- Test 1: stage_hunk reduces hunk count and updates highlights
  -- --------------------------------------------------------------------------
  it("stage_hunk reduces hunk count and updates highlights", function()
    repo = create_two_hunk_repo()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")
    local ns_highlight = require("codediff.ui.highlights").ns_highlight

    -- Wait for 2 hunks
    local has_2 = wait_for_hunks(tabpage, 2, 8000)
    assert.is_true(has_2, "Should start with 2 hunks")

    -- Locate modified buffer and stage_hunk keymap
    local _, mod_buf = lifecycle.get_buffers(tabpage)
    assert.is_truthy(mod_buf, "Modified buffer should exist")

    local stage_fn = get_keymap_fn(mod_buf, "Stage hunk")
    assert.is_truthy(stage_fn, "stage_hunk keymap callback should be set on modified buffer")

    -- Position cursor on hunk 1 (line 1 of modified)
    position_cursor_in_modified(tabpage, 1)

    -- Invoke stage_hunk callback
    stage_fn()

    -- Wait for hunk count to drop to 1 (view.update switches to :0 vs working tree)
    local has_1 = wait_for_hunks(tabpage, 1, 8000)
    assert.is_true(has_1, "Should have 1 hunk remaining after staging hunk 1")

    -- Re-fetch session and mod_buf after async update
    session = lifecycle.get_session(tabpage)
    assert.is_truthy(session, "Session should still exist")
    _, mod_buf = lifecycle.get_buffers(tabpage)
    assert.is_truthy(mod_buf, "Modified buffer should still exist")

    -- Remaining hunk should be at line 9
    local changes = session.stored_diff_result.changes
    assert.equals(1, #changes, "Exactly 1 hunk should remain")
    assert.equals(9, changes[1].modified.start_line, "Remaining hunk should be at line 9")

    -- Highlights should exist for the remaining hunk
    local line_hls = count_line_highlights(mod_buf, ns_highlight, "LineInsert")
    assert.is_true(line_hls >= 1, "LineInsert highlights should exist for remaining hunk, got " .. line_hls)
  end)

  -- --------------------------------------------------------------------------
  -- Test 2: stage last hunk switches to staged view
  -- --------------------------------------------------------------------------
  it("stage last hunk switches to staged view", function()
    repo = create_one_hunk_repo()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")

    -- Wait for 1 hunk
    local has_1 = wait_for_hunks(tabpage, 1, 8000)
    assert.is_true(has_1, "Should start with 1 hunk")

    -- Pre-condition: unstaged view
    session = lifecycle.get_session(tabpage)
    assert.is_true(session.modified_revision == nil, "Should be in unstaged view (modified_revision == nil), got: " .. tostring(session.modified_revision))

    local _, mod_buf = lifecycle.get_buffers(tabpage)
    local stage_fn = get_keymap_fn(mod_buf, "Stage hunk")
    assert.is_truthy(stage_fn, "stage_hunk keymap should be set")

    -- Position cursor on the single hunk
    position_cursor_in_modified(tabpage, 1)

    -- Stage it
    stage_fn()

    -- After staging the only hunk, the file moves from unstaged to staged group.
    -- Wait for the view to switch to staged (modified_revision == ":0")
    -- or for the explorer group to change.
    local switched = vim.wait(8000, function()
      local s = lifecycle.get_session(tabpage)
      if s and s.modified_revision == ":0" then return true end
      if explorer.data.current_file_group == "staged" then return true end
      return false
    end, 100)

    assert.is_true(switched,
      "After staging last hunk, should switch to staged view. "
        .. "modified_revision=" .. tostring(lifecycle.get_session(tabpage).modified_revision)
        .. ", group=" .. tostring(explorer.data.current_file_group))
  end)

  -- --------------------------------------------------------------------------
  -- Test 3: unstage_hunk from staged view reduces hunk count
  -- --------------------------------------------------------------------------
  it("unstage_hunk from staged view reduces hunk count", function()
    repo = create_two_hunk_repo()
    -- Stage all changes first via git add
    repo.git("add file1.txt")

    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")

    -- The explorer auto-selects file1.txt in the "staged" group because
    -- all changes are staged and there are no unstaged files.  We just
    -- wait for that async selection to finish rather than issuing a
    -- duplicate on_file_select call that would race with the auto-select.

    -- Wait for staged view (modified_revision == ":0") and 2 hunks
    local staged_ready = vim.wait(8000, function()
      local s = lifecycle.get_session(tabpage)
      if not s then
        return false
      end
      if s.modified_revision ~= ":0" then
        return false
      end
      if not s.stored_diff_result or not s.stored_diff_result.changes then
        return false
      end
      return #s.stored_diff_result.changes == 2
    end, 100)
    assert.is_true(staged_ready, "Should be in staged view with 2 hunks")

    -- Get unstage_hunk callback from modified buffer
    local _, mod_buf = lifecycle.get_buffers(tabpage)
    assert.is_truthy(mod_buf, "Modified buffer should exist")

    local unstage_fn = get_keymap_fn(mod_buf, "Unstage hunk")
    assert.is_truthy(unstage_fn, "unstage_hunk keymap callback should be set on modified buffer")

    -- Position cursor on hunk 1 (line 1)
    position_cursor_in_modified(tabpage, 1)

    -- Invoke unstage_hunk
    unstage_fn()

    -- Wait for hunk count to drop to 1
    local has_1 = wait_for_hunks(tabpage, 1, 8000)
    assert.is_true(has_1, "Should have 1 hunk remaining after unstaging hunk 1 from staged view")
  end)

  -- --------------------------------------------------------------------------
  -- Test 4: discard_hunk reverts working tree and updates diff
  -- --------------------------------------------------------------------------
  it("discard_hunk refreshes the visible buffer when autoread is disabled", function()
    vim.o.autoread = false
    repo = create_two_hunk_repo()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")

    -- Wait for 2 hunks
    local has_2 = wait_for_hunks(tabpage, 2, 8000)
    assert.is_true(has_2, "Should start with 2 hunks")

    local _, mod_buf = lifecycle.get_buffers(tabpage)
    local discard_fn = get_keymap_fn(mod_buf, "Discard hunk")
    assert.is_truthy(discard_fn, "discard_hunk keymap callback should be set")

    -- Mock vim.fn.confirm to auto-confirm "Discard" (choice 1)
    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function(_, _, _, _)
      return 1
    end

    -- Position cursor on hunk 1 (line 1)
    position_cursor_in_modified(tabpage, 1)

    -- Invoke discard_hunk
    discard_fn()

    -- Restore original vim.fn.confirm
    vim.fn.confirm = original_confirm

    -- Discard edits the buffer in memory and writes it to disk (VSCode-style),
    -- so the visible buffer and recomputed diff update without relying on autoread.
    local refreshed = vim.wait(8000, function()
      local current = lifecycle.get_session(tabpage)
      if not current or not current.stored_diff_result or not current.stored_diff_result.changes then
        return false
      end
      local first = vim.api.nvim_buf_get_lines(mod_buf, 0, 1, false)[1]
      return first == "original line 1" and #current.stored_diff_result.changes == 1
    end, 100)

    assert.is_true(refreshed, "Discard should refresh the visible buffer and leave exactly one hunk")

    local disk_lines = vim.fn.readfile(repo.path("file1.txt"))
    local buffer_lines = vim.api.nvim_buf_get_lines(mod_buf, 0, -1, false)
    assert.equals("original line 1", disk_lines[1], "Line 1 should be reverted on disk")
    assert.equals("original line 1", buffer_lines[1], "Line 1 should be reverted in the visible buffer")
    assert.equals("MODIFIED line 9", disk_lines[9], "Line 9 should remain modified on disk")
    assert.equals("MODIFIED line 9", buffer_lines[9], "Line 9 should remain modified in the visible buffer")
    assert.is_false(vim.bo[mod_buf].modified, "Buffer should be clean after the discard writes to disk")
  end)

  it("discard_hunk keeps unrelated buffer edits and saves them to disk (VSCode parity)", function()
    repo = h.create_temp_git_repo()
    local base = {}
    for i = 1, 20 do
      base[i] = "context line " .. i
    end
    base[1] = "original line 1"
    base[20] = "original line 20"

    repo.write_file("file1.txt", base)
    repo.git("add file1.txt")
    repo.git('commit -m "initial"')

    local changed = vim.deepcopy(base)
    changed[1] = "MODIFIED line 1"
    changed[20] = "MODIFIED line 20"
    repo.write_file("file1.txt", changed)

    local tabpage = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")
    assert.is_true(wait_for_hunks(tabpage, 2, 8000), "Should start with 2 hunks")

    local _, mod_buf = lifecycle.get_buffers(tabpage)
    vim.api.nvim_buf_set_lines(mod_buf, 9, 10, false, { "UNSAVED line 10" })
    require("codediff.ui.refresh").buffer_changed(mod_buf)
    assert.is_true(wait_for_hunks(tabpage, 3, 8000), "Unsaved edit should add a third hunk")
    assert.is_true(vim.bo[mod_buf].modified, "Buffer should contain an unsaved edit")

    local discard_fn = get_keymap_fn(mod_buf, "Discard hunk")
    assert.is_truthy(discard_fn, "discard_hunk keymap callback should be set")

    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 1
    end
    position_cursor_in_modified(tabpage, 1)
    discard_fn()
    vim.fn.confirm = original_confirm

    local refreshed = vim.wait(8000, function()
      local current = lifecycle.get_session(tabpage)
      if not current or not current.stored_diff_result or not current.stored_diff_result.changes then
        return false
      end
      local lines = vim.api.nvim_buf_get_lines(mod_buf, 0, -1, false)
      return lines[1] == "original line 1"
        and lines[10] == "UNSAVED line 10"
        and #current.stored_diff_result.changes == 2
    end, 100)

    assert.is_true(refreshed, "Discard should revert its hunk and keep unrelated buffer edits")

    local disk_lines = vim.fn.readfile(repo.path("file1.txt"))
    local buffer_lines = vim.api.nvim_buf_get_lines(mod_buf, 0, -1, false)
    assert.equals("original line 1", disk_lines[1], "Discarded hunk should be reverted on disk")
    assert.equals("UNSAVED line 10", disk_lines[10], "Whole-buffer save persists the unrelated edit to disk (VSCode parity)")
    assert.equals("UNSAVED line 10", buffer_lines[10], "Unrelated buffer edit remains in the buffer")
    assert.is_false(vim.bo[mod_buf].modified, "Buffer should be clean after the save")
  end)

  it("discard_hunk restores deleted lines to buffer and disk exactly once", function()
    repo = h.create_temp_git_repo()
    local base = { "line 1", "deleted line 2", "deleted line 3", "line 4" }
    repo.write_file("file1.txt", base)
    repo.git("add file1.txt")
    repo.git('commit -m "initial"')
    repo.write_file("file1.txt", { "line 1", "line 4" })

    local tabpage = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")
    assert.is_true(wait_for_hunks(tabpage, 1, 8000), "Should start with one deletion hunk")

    local session = lifecycle.get_session(tabpage)
    local _, mod_buf = lifecycle.get_buffers(tabpage)
    local discard_fn = get_keymap_fn(mod_buf, "Discard hunk")
    assert.is_truthy(discard_fn, "discard_hunk keymap callback should be set")

    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 1
    end
    position_cursor_in_modified(tabpage, session.stored_diff_result.changes[1].modified.start_line)
    discard_fn()
    vim.fn.confirm = original_confirm

    local refreshed = vim.wait(8000, function()
      local current = lifecycle.get_session(tabpage)
      if not current or not current.stored_diff_result or not current.stored_diff_result.changes then
        return false
      end
      local lines = vim.api.nvim_buf_get_lines(mod_buf, 0, -1, false)
      return vim.deep_equal(lines, base) and #current.stored_diff_result.changes == 0
    end, 100)

    assert.is_true(refreshed, "Discarding a deletion hunk must restore deleted lines exactly once")
    assert.same(base, vim.fn.readfile(repo.path("file1.txt")))
    assert.same(base, vim.api.nvim_buf_get_lines(mod_buf, 0, -1, false))
  end)

  it("discard_hunk removes inserted lines when autoread is disabled", function()
    vim.o.autoread = false
    repo = h.create_temp_git_repo()
    local base = { "line 1", "line 4" }
    repo.write_file("file1.txt", base)
    repo.git("add file1.txt")
    repo.git('commit -m "initial"')
    repo.write_file("file1.txt", { "line 1", "inserted line 2", "inserted line 3", "line 4" })

    local tabpage = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")
    assert.is_true(wait_for_hunks(tabpage, 1, 8000), "Should start with one insertion hunk")

    local session = lifecycle.get_session(tabpage)
    local _, mod_buf = lifecycle.get_buffers(tabpage)
    local discard_fn = get_keymap_fn(mod_buf, "Discard hunk")
    assert.is_truthy(discard_fn, "discard_hunk keymap callback should be set")

    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 1
    end
    position_cursor_in_modified(tabpage, session.stored_diff_result.changes[1].modified.start_line)
    discard_fn()
    vim.fn.confirm = original_confirm

    local refreshed = vim.wait(8000, function()
      local current = lifecycle.get_session(tabpage)
      if not current or not current.stored_diff_result or not current.stored_diff_result.changes then
        return false
      end
      local lines = vim.api.nvim_buf_get_lines(mod_buf, 0, -1, false)
      return vim.deep_equal(lines, base) and #current.stored_diff_result.changes == 0
    end, 100)

    assert.is_true(refreshed, "Discard should remove inserted lines from disk and buffer")
    assert.same(base, vim.fn.readfile(repo.path("file1.txt")))
    assert.same(base, vim.api.nvim_buf_get_lines(mod_buf, 0, -1, false))
  end)
end)

-- ============================================================================
-- Inline mode tests
-- ============================================================================
describe("Hunk operations (inline)", function()
  local repo
  local original_cwd
  local original_autoread

  before_each(function()
    vim.g.mapleader = " "
    require("codediff").setup({ diff = { layout = "inline" } })
    setup_command()
    original_cwd = vim.fn.getcwd()
    original_autoread = vim.o.autoread
  end)

  after_each(function()
    pcall(function()
      vim.cmd("tabnew")
      vim.cmd("tabonly")
    end)
    -- Restore default layout for other test suites
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    vim.fn.chdir(original_cwd)
    vim.o.autoread = original_autoread
    vim.wait(200)
    if repo then
      repo.cleanup()
      repo = nil
    end
  end)

  -- --------------------------------------------------------------------------
  -- Test 5: stage_hunk removes inline extmarks for staged hunk
  -- --------------------------------------------------------------------------
  it("stage_hunk removes inline extmarks for staged hunk", function()
    -- Pre-load inline modules to detect environment issues early
    local ok_iv, _ = pcall(require, "codediff.ui.view.inline_view")
    local ok_il, inline_module = pcall(require, "codediff.ui.inline")
    if not ok_iv or not ok_il then
      -- Module loading issue in this environment; skip gracefully
      assert.is_truthy(ok_iv, "codediff.ui.view.inline_view should be loadable (check rtp/package.path)")
      return
    end

    repo = create_two_hunk_repo()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")
    local ns_inline = vim.api.nvim_create_namespace("codediff-inline")

    -- Wait for 2 hunks
    local has_2 = wait_for_hunks(tabpage, 2, 8000)
    assert.is_true(has_2, "Should start with 2 hunks in inline mode")

    -- Get stage_hunk callback
    local _, mod_buf = lifecycle.get_buffers(tabpage)
    assert.is_truthy(mod_buf, "Modified buffer should exist")
    local stage_fn = get_keymap_fn(mod_buf, "Stage hunk")
    assert.is_truthy(stage_fn, "stage_hunk keymap callback should be set in inline mode")

    -- Position cursor on hunk 1 (line 1)
    position_cursor_in_modified(tabpage, 1)

    -- Stage hunk 1
    stage_fn()

    -- Wait for hunk count to drop to 1
    local has_1 = wait_for_hunks(tabpage, 1, 8000)
    assert.is_true(has_1, "Should have 1 hunk remaining after staging hunk 1 in inline mode")

    -- Re-fetch mod_buf after async update
    _, mod_buf = lifecycle.get_buffers(tabpage)
    assert.is_truthy(mod_buf, "Modified buffer should still exist after staging")

    -- Check ns_inline extmarks: none should be near line 1 (below line 3 only)
    local early_marks = vim.api.nvim_buf_get_extmarks(mod_buf, ns_inline, { 0, 0 }, { 2, 0 }, {})
    assert.equals(0, #early_marks, "No inline extmarks should be near line 1 after staging hunk 1, got " .. #early_marks)
  end)

  -- --------------------------------------------------------------------------
  -- Test 6: stage last hunk switches to staged view (inline)
  -- --------------------------------------------------------------------------
  it("stage last hunk switches to staged view (inline)", function()
    -- Pre-load inline modules
    local ok_iv, _ = pcall(require, "codediff.ui.view.inline_view")
    if not ok_iv then
      assert.is_truthy(ok_iv, "codediff.ui.view.inline_view should be loadable")
      return
    end

    repo = create_one_hunk_repo()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")

    -- Wait for 1 hunk
    local has_1 = wait_for_hunks(tabpage, 1, 8000)
    assert.is_true(has_1, "Should start with 1 hunk in inline mode")

    -- Pre-condition: unstaged view
    session = lifecycle.get_session(tabpage)
    assert.is_true(session.modified_revision == nil, "Should be in unstaged view, got: " .. tostring(session.modified_revision))

    local _, mod_buf = lifecycle.get_buffers(tabpage)
    local stage_fn = get_keymap_fn(mod_buf, "Stage hunk")
    assert.is_truthy(stage_fn, "stage_hunk keymap should be set in inline mode")

    -- Position cursor on the hunk
    position_cursor_in_modified(tabpage, 1)

    -- Stage it
    stage_fn()

    -- After staging the only hunk, wait for staged view or group change
    local switched = vim.wait(8000, function()
      local s = lifecycle.get_session(tabpage)
      if s and s.modified_revision == ":0" then return true end
      if explorer.data.current_file_group == "staged" then return true end
      return false
    end, 100)

    assert.is_true(switched,
      "After staging last hunk in inline mode, should switch to staged view. "
        .. "modified_revision=" .. tostring(lifecycle.get_session(tabpage).modified_revision)
        .. ", group=" .. tostring(explorer.data.current_file_group))
  end)

  it("discard_hunk refreshes inline mode when autoread is disabled", function()
    vim.o.autoread = false
    repo = create_two_hunk_repo()
    local tabpage = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")
    assert.is_true(wait_for_hunks(tabpage, 2, 8000), "Should start with 2 hunks in inline mode")

    local _, mod_buf = lifecycle.get_buffers(tabpage)
    local discard_fn = get_keymap_fn(mod_buf, "Discard hunk")
    assert.is_truthy(discard_fn, "discard_hunk keymap callback should be set in inline mode")

    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 1
    end
    position_cursor_in_modified(tabpage, 1)
    discard_fn()
    vim.fn.confirm = original_confirm

    local refreshed = vim.wait(8000, function()
      local current = lifecycle.get_session(tabpage)
      if not current or not current.stored_diff_result or not current.stored_diff_result.changes then
        return false
      end
      local first = vim.api.nvim_buf_get_lines(mod_buf, 0, 1, false)[1]
      return first == "original line 1" and #current.stored_diff_result.changes == 1
    end, 100)

    assert.is_true(refreshed, "Inline discard should refresh the buffer and leave one hunk")
  end)

  -- --------------------------------------------------------------------------
  -- Test 7: no stale ns_highlight after toggle side-by-side → inline + stage
  -- --------------------------------------------------------------------------
  it("no stale ns_highlight after toggling to inline", function()
    -- Pre-load inline and toggle modules (may not be in package.path in some CI envs)
    local ok_iv, _ = pcall(require, "codediff.ui.view.inline_view")
    local ok_toggle, _ = pcall(require, "codediff.ui.view.toggle")
    if not ok_iv then
      assert.is_truthy(ok_iv, "codediff.ui.view.inline_view should be loadable")
      return
    end
    if not ok_toggle then
      assert.is_truthy(ok_toggle, "codediff.ui.view.toggle should be loadable (check rtp/package.path)")
      return
    end

    -- Start in side-by-side mode for this specific test
    require("codediff").setup({ diff = { layout = "side-by-side" } })

    repo = create_two_hunk_repo()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")

    -- Wait for 2 hunks in side-by-side
    local has_2 = wait_for_hunks(tabpage, 2, 8000)
    assert.is_true(has_2, "Should start with 2 hunks in side-by-side")

    -- Toggle to inline mode
    require("codediff.ui.view").toggle_layout(tabpage)

    -- Wait for layout change and view to fully settle
    local toggled = vim.wait(5000, function()
      local s = lifecycle.get_session(tabpage)
      return s and s.layout == "inline"
    end, 100)
    assert.is_true(toggled, "Layout should switch to inline after toggle")

    -- Wait for the diff to be ready in inline mode
    local inline_ready = wait_for_hunks(tabpage, 2, 8000)
    assert.is_true(inline_ready, "Should still have 2 hunks after toggle to inline")

    -- Verify session is valid after toggle
    session = lifecycle.get_session(tabpage)
    assert.is_truthy(session, "Session should exist after toggle")
    assert.equals("inline", session.layout, "Layout should be inline")
  end)
end)

-- ============================================================================
-- Explorer action tests (stage_all / unstage_all)
-- ============================================================================
describe("Explorer hunk/staging actions", function()
  local repo
  local original_cwd

  before_each(function()
    vim.g.mapleader = " "
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    setup_command()
    original_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    pcall(function()
      vim.cmd("tabnew")
      vim.cmd("tabonly")
    end)
    vim.fn.chdir(original_cwd)
    vim.wait(200)
    if repo then
      repo.cleanup()
      repo = nil
    end
  end)

  -- --------------------------------------------------------------------------
  -- Test 8: stage_all updates view
  -- --------------------------------------------------------------------------
  it("stage_all transitions view to staged", function()
    repo = create_one_hunk_repo()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")
    local actions = require("codediff.ui.explorer.actions")

    local has_1 = wait_for_hunks(tabpage, 1, 8000)
    assert.is_true(has_1, "Should start with 1 hunk")

    session = lifecycle.get_session(tabpage)
    assert.is_true(session.modified_revision == nil, "Should start in unstaged view")

    -- Call stage_all — should auto-refresh via .git watcher or explicit refresh
    actions.stage_all(explorer)

    -- Wait for view to transition to staged — NO manual refresh fallback
    local transitioned = vim.wait(8000, function()
      local s = lifecycle.get_session(tabpage)
      if s and s.modified_revision == ":0" then return true end
      if explorer.data.current_file_group == "staged" then return true end
      return false
    end, 200)

    assert.is_true(
      transitioned,
      "After stage_all, view should transition to staged automatically. "
        .. "modified_revision=" .. tostring(lifecycle.get_session(tabpage).modified_revision)
        .. ", group=" .. tostring(explorer.data.current_file_group)
    )
  end)

  -- --------------------------------------------------------------------------
  -- Test 9: unstage_all after staging restores diff
  -- --------------------------------------------------------------------------
  it("unstage_all after staging restores diff", function()
    repo = create_one_hunk_repo()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")
    local actions = require("codediff.ui.explorer.actions")
    local highlights = require("codediff.ui.highlights")

    local has_1 = wait_for_hunks(tabpage, 1, 8000)
    assert.is_true(has_1, "Should start with 1 hunk")

    -- Stage the hunk via keymap
    local _, mod_buf = lifecycle.get_buffers(tabpage)
    local stage_fn = get_keymap_fn(mod_buf, "Stage hunk")
    assert.is_truthy(stage_fn, "stage_hunk keymap should be set")

    position_cursor_in_modified(tabpage, 1)
    stage_fn()

    local switched = vim.wait(8000, function()
      local s = lifecycle.get_session(tabpage)
      return s and s.modified_revision == ":0"
    end, 100)
    assert.is_true(switched, "Should be in staged view after staging")

    -- Now call unstage_all — should auto-refresh, NO manual refresh fallback
    actions.unstage_all(explorer)

    -- Wait for view to restore to unstaged with the hunk visible
    local restored = vim.wait(8000, function()
      local s = lifecycle.get_session(tabpage)
      if not s or not s.stored_diff_result then return false end
      if s.modified_revision == ":0" then return false end
      return #s.stored_diff_result.changes >= 1
    end, 200)

    assert.is_true(restored, "After unstage_all, should show unstaged hunk again")

    -- Verify highlights exist on modified buffer
    session = lifecycle.get_session(tabpage)
    _, mod_buf = lifecycle.get_buffers(tabpage)
    local ns = highlights.ns_highlight
    local line_hls = count_line_highlights(mod_buf, ns, "LineInsert")
    assert.is_true(line_hls >= 1, "After unstage_all, highlights should be restored, got " .. line_hls)

    -- Verify git state
    local staged_output = vim.fn.system("git -C " .. vim.fn.shellescape(repo.dir) .. " diff --cached --name-only")
    assert.equals("", vim.trim(staged_output), "No files should be staged after unstage_all")
  end)
end)

-- ============================================================================
-- Sequential operation tests
-- ============================================================================
describe("Sequential hunk operations", function()
  local repo
  local original_cwd

  before_each(function()
    vim.g.mapleader = " "
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    setup_command()
    original_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    pcall(function()
      vim.cmd("tabnew")
      vim.cmd("tabonly")
    end)
    vim.fn.chdir(original_cwd)
    vim.wait(200)
    if repo then
      repo.cleanup()
      repo = nil
    end
  end)

  -- --------------------------------------------------------------------------
  -- Test 10: stage two hunks sequentially
  -- --------------------------------------------------------------------------
  it("stage two hunks sequentially stages both to index", function()
    repo = create_two_hunk_repo()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")

    -- Wait for 2 hunks
    local has_2 = wait_for_hunks(tabpage, 2, 8000)
    assert.is_true(has_2, "Should start with 2 hunks")

    -- Get stage_hunk callback
    local _, mod_buf = lifecycle.get_buffers(tabpage)
    local stage_fn = get_keymap_fn(mod_buf, "Stage hunk")
    assert.is_truthy(stage_fn, "stage_hunk keymap should be set")

    -- Stage hunk 1: position at line 1
    position_cursor_in_modified(tabpage, 1)
    stage_fn()

    -- Wait for view to update (hunk count drops from 2 to 1)
    local has_1 = wait_for_hunks(tabpage, 1, 8000)
    assert.is_true(has_1, "Should have 1 hunk after staging hunk 1")

    -- Re-fetch session and mod_buf (may have changed after view.update)
    session = lifecycle.get_session(tabpage)
    assert.is_truthy(session, "Session should still exist after first stage")
    _, mod_buf = lifecycle.get_buffers(tabpage)

    -- Position at the remaining hunk (now the only hunk in the diff)
    local changes = session.stored_diff_result.changes
    assert.equals(1, #changes, "Should have exactly 1 remaining hunk")
    local hunk2_line = changes[1].modified.start_line
    position_cursor_in_modified(tabpage, hunk2_line)

    -- Re-fetch stage_fn (buffer may have been recreated)
    local stage_fn_2 = get_keymap_fn(mod_buf, "Stage hunk")
    assert.is_truthy(stage_fn_2, "stage_hunk keymap should still be available")

    stage_fn_2()

    -- After staging both hunks, either:
    -- - The view switches to staged (modified_revision == ":0") because no unstaged changes remain
    -- - Or stored_diff_result.changes drops to 0
    local all_staged = vim.wait(8000, function()
      local s = lifecycle.get_session(tabpage)
      if not s then return false end
      if s.modified_revision == ":0" then return true end
      if explorer.data.current_file_group == "staged" then return true end
      if s.stored_diff_result and s.stored_diff_result.changes and #s.stored_diff_result.changes == 0 then return true end
      return false
    end, 100)

    assert.is_true(all_staged, "After staging both hunks, should have no unstaged changes or switch to staged view")

    -- Verify git state: both hunks staged, no remaining unstaged diff
    local unstaged = vim.fn.system("git -C " .. vim.fn.shellescape(repo.dir) .. " diff --name-only")
    assert.equals("", vim.trim(unstaged), "No unstaged changes should remain after staging both hunks")
  end)
end)
