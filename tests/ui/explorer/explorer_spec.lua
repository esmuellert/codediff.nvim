-- Test: Explorer Mode
-- Validates git status explorer functionality, window management, and file selection

local git = require('codediff.core.git')
local config = require("codediff.config")
local h = dofile('tests/helpers.lua')

-- Setup CodeDiff command for tests
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

-- Open a fresh CodeDiff explorer for `focus_file` and return (tabpage, explorer).
-- Earlier tests leave sessions and pending vim.schedule callbacks in the
-- lifecycle singleton, so flush + cleanup first, then pick up the explorer
-- created by THIS :CodeDiff (the one whose buffer carries the auto-open
-- buffer-local j keymap).
local function open_explorer(temp_dir, focus_file)
  local lifecycle = require("codediff.ui.lifecycle")
  vim.wait(200)
  lifecycle.cleanup_all()

  vim.cmd("edit " .. temp_dir .. "/" .. focus_file)
  vim.cmd("CodeDiff")

  local tabpage, explorer
  local ready = vim.wait(6000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local e = lifecycle.get_panel_view(tp)
      if e and e.winid and vim.api.nvim_win_is_valid(e.winid)
          and e.bufnr and vim.api.nvim_buf_is_valid(e.bufnr)
          and e.current_file_path ~= nil then
        -- Pick the explorer wired with the auto-open j/k keymap; leftover
        -- explorers from prior tests (default config) lack it.
        local maps = vim.api.nvim_buf_get_keymap(e.bufnr, "n")
        for _, m in ipairs(maps) do
          if m.lhs == "j" and (m.desc or ""):find("codediff: move and auto%-open") then
            tabpage = tp
            explorer = e
            return true
          end
        end
      end
    end
    return false
  end, 50)
  return ready, tabpage, explorer
end

local function open_initial_explorer(temp_dir, view_mode, ignore_patterns)
  local lifecycle = require("codediff.ui.lifecycle")
  vim.wait(200)
  lifecycle.cleanup_all()
  require("codediff").setup({
    diff = { layout = "side-by-side" },
    explorer = {
      view_mode = view_mode,
      file_filter = { ignore = ignore_patterns or config.defaults.explorer.file_filter.ignore },
    },
  })

  vim.fn.writefile({ "modified nested" }, temp_dir .. "/nested/deep.txt")
  vim.cmd("enew")
  vim.cmd("CodeDiff")

  local explorer, session
  local ready = vim.wait(6000, function()
    explorer = lifecycle.get_panel_view(vim.api.nvim_get_current_tabpage())
    if not explorer or not explorer.current_file_path then
      return false
    end
    session = lifecycle.get_session(explorer.tabpage)
    if not session or type(session.original) ~= "table" or type(session.modified) ~= "table" then
      return false
    end
    return session.original.relative ~= "" and session.modified.relative ~= ""
  end, 20)
  assert.is_true(ready, "Explorer should complete its initial selection")
  return explorer, session
end

local function assert_first_visible_file_selected(explorer, session, expected_path)
  local first_path
  for line = 1, vim.api.nvim_buf_line_count(explorer.bufnr) do
    local node = explorer.tree:get_node(line)
    if node and node.data and node.data.path then
      first_path = node.data.path
      break
    end
  end

  local cursor_line = vim.api.nvim_win_get_cursor(explorer.winid)[1]
  local cursor_node = explorer.tree:get_node(cursor_line)
  assert.equals(expected_path, first_path)
  assert.equals(first_path, explorer.current_file_path)
  assert.equals(first_path, cursor_node.data.path)
  assert.equals(first_path, session.original.relative)
  assert.equals(first_path, session.modified.relative)
end

local function find_file_node(explorer, predicate)
  for line = 1, vim.api.nvim_buf_line_count(explorer.bufnr) do
    local node = explorer.tree:get_node(line)
    local data = node and node.data
    if data and data.path and predicate(data) then
      return line, data.path, data.group
    end
  end
end

describe("Explorer Mode", function()
  local temp_dir
  local original_cwd

  before_each(function()
    config.options = vim.deepcopy(config.defaults)
    require("codediff").setup({
      diff = { layout = "side-by-side" },
      explorer = { view_mode = "list" },
    })
    -- Setup command
    setup_command()
    
    -- Save original working directory
    original_cwd = vim.fn.getcwd()
    
    -- Create temporary git repository for testing
    temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
    vim.fn.chdir(temp_dir)
    
    -- Initialize git repo
    h.git_cmd(temp_dir, "init")
    h.git_cmd(temp_dir, "branch -m main")
    h.git_cmd(temp_dir, 'config user.email "test@example.com"')
    h.git_cmd(temp_dir, 'config user.name "Test User"')
    
    -- Create and commit initial file
    vim.fn.writefile({"line 1", "line 2"}, temp_dir .. "/file1.txt")
    vim.fn.mkdir(temp_dir .. "/nested", "p")
    vim.fn.writefile({ "original nested" }, temp_dir .. "/nested/deep.txt")
    h.git_cmd(temp_dir, "add file1.txt nested/deep.txt")
    local commit_result = h.git_cmd(temp_dir, 'commit -m "Initial commit"')
    assert(vim.v.shell_error == 0, "git commit failed: " .. commit_result)
    
    -- Modify file (unstaged)
    vim.fn.writefile({"line 1", "line 2 modified", "line 3"}, temp_dir .. "/file1.txt")
    
    -- Create new file (staged)
    vim.fn.writefile({"new file"}, temp_dir .. "/file2.txt")
    h.git_cmd(temp_dir, "add file2.txt")
    
    -- Create untracked file
    vim.fn.writefile({"untracked"}, temp_dir .. "/file3.txt")
  end)

  after_each(function()
    -- Ensure we are not in a diff session (which might be the only tab)
    -- Create a new tab to be safe
    vim.cmd("tabnew")
    -- Close all other tabs (including any diff tabs)
    vim.cmd("tabonly")
    
    -- Clean up and restore
    vim.fn.chdir(original_cwd)
    
    -- Wait for async operations to complete before deleting temp directory
    vim.wait(200)
    
    if temp_dir and vim.fn.isdirectory(temp_dir) == 1 then
      vim.fn.delete(temp_dir, "rf")
    end
  end)

  -- Test 1: Git status parsing
  it("Parses git status correctly", function()
    local callback_called = false
    local status_result = nil
    
    git.get_status(temp_dir, function(err, result)
      callback_called = true
      if not err then
        status_result = result
      end
    end)
    
    vim.wait(2000, function() return callback_called end)
    assert.is_true(callback_called, "Callback should be invoked")
    assert.is_not_nil(status_result, "Status result should not be nil")
    assert.is_table(status_result.unstaged, "Should have unstaged table")
    assert.is_table(status_result.staged, "Should have staged table")
    assert.is_table(status_result.conflicts, "Should have conflicts table")
    
    -- Should have at least one unstaged file (file1.txt modified)
    assert.is_true(#status_result.unstaged >= 1, "Should have unstaged changes")
    
    -- Should have at least one staged file (file2.txt added)
    assert.is_true(#status_result.staged >= 1, "Should have staged changes")
  end)

  -- Test 2: Git status detects file types correctly
  it("Detects modified, added, and untracked files", function()
    local callback_called = false
    local status_result = nil
    
    git.get_status(temp_dir, function(err, result)
      callback_called = true
      status_result = result
    end)
    
    vim.wait(2000, function() return callback_called end)
    assert.is_true(callback_called)
    
    -- Check for modified file in unstaged
    local has_modified = false
    for _, file in ipairs(status_result.unstaged) do
      if file.path == "file1.txt" and file.status == "M" then
        has_modified = true
      end
    end
    assert.is_true(has_modified, "Should detect modified file")
    
    -- Check for added file in staged
    local has_added = false
    for _, file in ipairs(status_result.staged) do
      if file.path == "file2.txt" and file.status == "A" then
        has_added = true
      end
    end
    assert.is_true(has_added, "Should detect added file")
    
    -- Check for untracked file
    local has_untracked = false
    for _, file in ipairs(status_result.unstaged) do
      if file.path == "file3.txt" and file.status == "??" then
        has_untracked = true
      end
    end
    assert.is_true(has_untracked, "Should detect untracked file")
  end)

  -- Test 2.5: Git status detects merge conflicts
  it("Detects merge conflicts", function()
    -- Create a branch and make conflicting changes
    h.git_cmd(temp_dir, "checkout -b feature")
    vim.fn.writefile({"feature line 1", "line 2"}, temp_dir .. "/file1.txt")
    h.git_cmd(temp_dir, "add file1.txt")
    h.git_cmd(temp_dir, 'commit -m "Feature change"')
    
    h.git_cmd(temp_dir, "checkout main")
    vim.fn.writefile({"master line 1", "line 2"}, temp_dir .. "/file1.txt")
    h.git_cmd(temp_dir, "add file1.txt")
    h.git_cmd(temp_dir, 'commit -m "Master change"')
    
    -- Attempt merge (will fail with conflict)
    h.git_cmd(temp_dir, "merge feature")
    
    local callback_called = false
    local status_result = nil
    
    git.get_status(temp_dir, function(err, result)
      callback_called = true
      status_result = result
    end)
    
    vim.wait(2000, function() return callback_called end)
    assert.is_true(callback_called)
    
    -- Check for conflict file
    local has_conflict = false
    for _, file in ipairs(status_result.conflicts) do
      if file.path == "file1.txt" and file.status == "!" then
        has_conflict = true
      end
    end
    assert.is_true(has_conflict, "Should detect merge conflict")
    
    -- Abort merge to clean up
    h.git_cmd(temp_dir, "merge --abort")
  end)

  -- Test 3: Explorer creates proper window layout
  it("Creates correct window layout", function()
    local initial_tabs = vim.fn.tabpagenr('$')
    
    -- Open explorer
    vim.cmd("edit " .. temp_dir .. "/file1.txt")
    vim.cmd("CodeDiff")
    
    -- Wait for async operations
    vim.wait(3000, function()
      return vim.fn.tabpagenr('$') > initial_tabs
    end)
    
    -- Should create new tab
    assert.is_true(vim.fn.tabpagenr('$') > initial_tabs, "Should create new tab")
    
    -- Should have 3 windows (explorer + 2 diff panes)
    local wincount = vim.fn.winnr('$')
    assert.equal(3, wincount, "Should have 3 windows")
    
    -- Check for explorer window
    local has_explorer = false
    for i = 1, wincount do
      local winid = vim.fn.win_getid(i)
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].filetype == "codediff-explorer" then
        has_explorer = true
        break
      end
    end
    assert.is_true(has_explorer, "Should have explorer window")
  end)

  it("Recreates manually closed diff windows when another file is selected", function()
    local lifecycle = require("codediff.ui.lifecycle")
    vim.wait(200)
    lifecycle.cleanup_all()

    vim.fn.writefile({ "modified nested" }, temp_dir .. "/nested/deep.txt")
    vim.cmd("edit " .. temp_dir .. "/file1.txt")
    vim.cmd("CodeDiff")

    local tabpage
    local session
    local explorer
    local ready = vim.wait(6000, function()
      for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
        local candidate = lifecycle.get_session(tp)
        local candidate_explorer = lifecycle.get_panel_view(tp)
        if
          candidate_explorer
          and candidate_explorer.current_file_path ~= nil
          and candidate.original_win
          and candidate.modified_win
          and vim.api.nvim_win_is_valid(candidate.original_win)
          and vim.api.nvim_win_is_valid(candidate.modified_win)
        then
          tabpage = tp
          session = candidate
          explorer = candidate_explorer
          return true
        end
      end
      return false
    end, 20)
    assert.is_true(ready, "Explorer diff should be ready")

    local target_line
    local target_path
    for line = 1, vim.api.nvim_buf_line_count(explorer.bufnr) do
      local node = explorer.tree:get_node(line)
      if node and node.data and node.data.path and node.data.path ~= explorer.current_file_path and node.data.status == "M" then
        target_line = line
        target_path = node.data.path
        break
      end
    end
    assert.is_not_nil(target_line, "Should find another modified file")

    local closed_win = session.modified_win
    vim.api.nvim_set_current_win(closed_win)
    vim.cmd("close")
    vim.wait(200)

    assert.is_false(vim.api.nvim_win_is_valid(closed_win), "Modified window should be closed")
    assert.is_not_nil(lifecycle.get_session(tabpage), "Explorer session should survive one closed diff window")
    assert.is_true(vim.api.nvim_win_is_valid(explorer.winid), "Explorer window should remain open")

    vim.api.nvim_set_current_win(explorer.winid)
    vim.api.nvim_win_set_cursor(explorer.winid, { target_line, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "tx", false)

    local repaired = vim.wait(6000, function()
      session = lifecycle.get_session(tabpage)
      if
        not session
        or not session.original_win
        or not session.modified_win
        or not vim.api.nvim_win_is_valid(session.original_win)
        or not vim.api.nvim_win_is_valid(session.modified_win)
      then
        return false
      end
      return session.modified.relative == target_path
    end, 20)

    assert.is_true(repaired, "Selecting another file should recreate both diff windows")
    assert.is_true(vim.api.nvim_win_is_valid(explorer.winid), "Explorer should be preserved after repair")
    assert.equals(3, #vim.api.nvim_tabpage_list_wins(tabpage), "Explorer and two diff windows should be open")

    local next_line
    local next_path
    for line = 1, vim.api.nvim_buf_line_count(explorer.bufnr) do
      local node = explorer.tree:get_node(line)
      if node and node.data and node.data.path and node.data.path ~= explorer.current_file_path and node.data.status == "M" then
        next_line = line
        next_path = node.data.path
        break
      end
    end
    assert.is_not_nil(next_line, "Should find a file to select after both panes close")

    local closed_original = session.original_win
    local closed_modified = session.modified_win
    vim.api.nvim_win_close(closed_original, false)
    vim.api.nvim_win_close(closed_modified, false)
    vim.wait(200)

    assert.is_false(vim.api.nvim_win_is_valid(closed_original), "Original window should be closed")
    assert.is_false(vim.api.nvim_win_is_valid(closed_modified), "Modified window should be closed")
    assert.is_not_nil(lifecycle.get_session(tabpage), "Explorer session should survive both closed diff windows")
    assert.is_true(vim.api.nvim_win_is_valid(explorer.winid), "Explorer should be the remaining window")

    vim.api.nvim_set_current_win(explorer.winid)
    vim.api.nvim_win_set_cursor(explorer.winid, { next_line, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "tx", false)

    local both_repaired = vim.wait(6000, function()
      session = lifecycle.get_session(tabpage)
      if
        not session
        or not session.original_win
        or not session.modified_win
        or not vim.api.nvim_win_is_valid(session.original_win)
        or not vim.api.nvim_win_is_valid(session.modified_win)
      then
        return false
      end
      return session.modified.relative == next_path
    end, 20)

    assert.is_true(both_repaired, "Selecting another file should recreate both closed diff windows")
    assert.is_true(vim.api.nvim_win_is_valid(explorer.winid), "Explorer should remain open after both panes are repaired")
    assert.equals(3, #vim.api.nvim_tabpage_list_wins(tabpage), "Explorer and both recreated diff windows should be open")
  end)

  -- Test 4: Window widths are properly distributed
  for _, closed_side in ipairs({ "original", "modified", "both" }) do
    it("Reopens the same file after closing " .. closed_side .. " panes", function()
      local explorer, session = open_initial_explorer(temp_dir, "list")
      assert.is_true(h.wait_for_diff_ready())
      if closed_side ~= "modified" then
        vim.api.nvim_win_close(session.original_win, false)
      end
      if closed_side ~= "original" then
        vim.api.nvim_win_close(session.modified_win, false)
      end
      vim.wait(100)

      explorer.on_file_select(vim.deepcopy(explorer.current_selection))
      assert.is_true(vim.wait(2000, function()
        return session.original_win and vim.api.nvim_win_is_valid(session.original_win)
          and session.modified_win and vim.api.nvim_win_is_valid(session.modified_win)
      end, 10), "Selecting the same file must restore its panes")
      assert.is_true(h.wait_for_diff_ready())
      assert.equals(3, #vim.api.nvim_tabpage_list_wins(explorer.tabpage))
    end)
  end

  for _, target in ipairs({
    { path = "file3.txt", status = "??", group = "unstaged", side = "modified", content = "untracked" },
    { path = "file2.txt", status = "A", group = "staged", side = "modified", content = "new file" },
    { path = "nested/deep.txt", status = "D", group = "unstaged", side = "original", content = "original nested" },
  }) do
    it("Opens a " .. target.status .. " file after both panes close", function()
      local explorer, session = open_initial_explorer(temp_dir, "list")
      assert.is_true(h.wait_for_diff_ready())
      if target.status == "D" then
        vim.fn.delete(temp_dir .. "/" .. target.path)
      end
      vim.api.nvim_win_close(session.original_win, false)
      vim.api.nvim_win_close(session.modified_win, false)
      vim.wait(100)

      explorer.on_file_select(target)
      assert.is_true(vim.wait(2000, function()
        local win = session[target.side .. "_win"]
        return win and vim.api.nvim_win_is_valid(win)
          and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, 1, false)[1] == target.content
      end, 10), "Selection must restore a pane with the file content")
      assert.equals(2, #vim.api.nvim_tabpage_list_wins(explorer.tabpage))
      assert.equals(target.side, session.single_side)
    end)
  end

  it("Distributes window widths correctly", function()
    vim.o.columns = 160  -- Set known terminal width
    
    vim.cmd("edit " .. temp_dir .. "/file1.txt")
    vim.cmd("CodeDiff")
    
    -- Wait longer and check for explorer specifically
    local has_explorer = false
    vim.wait(5000, function()
      if vim.fn.winnr('$') ~= 3 then return false end
      for i = 1, vim.fn.winnr('$') do
        local winid = vim.fn.win_getid(i)
        local bufnr = vim.api.nvim_win_get_buf(winid)
        if vim.bo[bufnr].filetype == "codediff-explorer" then
          has_explorer = true
          return true
        end
      end
      return false
    end)
    
    if not has_explorer then
      pending("Explorer not created in time")
      return
    end
    
    local explorer_width = nil
    local diff_widths = {}
    
    for i = 1, vim.fn.winnr('$') do
      local winid = vim.fn.win_getid(i)
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local width = vim.api.nvim_win_get_width(winid)
      
      if vim.bo[bufnr].filetype == "codediff-explorer" then
        explorer_width = width
      elseif vim.bo[bufnr].filetype ~= "" then
        table.insert(diff_widths, width)
      end
    end
    
    -- Explorer should be 20-35 columns
    assert.is_not_nil(explorer_width, "Explorer should have width")
    assert.is_true(explorer_width >= 15 and explorer_width <= 40, 
      "Explorer width should be reasonable (got " .. tostring(explorer_width) .. ")")
    
    -- Diff panes should be roughly equal
    if #diff_widths == 2 then
      local diff = math.abs(diff_widths[1] - diff_widths[2])
      assert.is_true(diff <= 5, "Diff panes should have nearly equal width (diff: " .. diff .. ")")
    end
  end)

  -- Test 5: Explorer shows correct content structure
  it("Shows correct explorer content structure", function()
    vim.cmd("edit " .. temp_dir .. "/file1.txt")
    vim.cmd("CodeDiff")
    
    -- Wait for explorer to be created
    local explorer_buf = nil
    vim.wait(5000, function()
      for i = 1, vim.fn.winnr('$') do
        local winid = vim.fn.win_getid(i)
        local bufnr = vim.api.nvim_win_get_buf(winid)
        if vim.bo[bufnr].filetype == "codediff-explorer" then
          explorer_buf = bufnr
          return true
        end
      end
      return false
    end)
    
    if not explorer_buf then
      pending("Explorer buffer not created in time")
      return
    end
    
    local lines = vim.api.nvim_buf_get_lines(explorer_buf, 0, -1, false)
    
    -- Should have group headers
    local has_changes_group = false
    local has_staged_group = false
    local has_file_count = false
    local has_status_symbol = false
    
    for _, line in ipairs(lines) do
      if line:match("Changes") then has_changes_group = true end
      if line:match("Staged") then has_staged_group = true end
      if line:match("%(%d+%)") then has_file_count = true end
      if line:match("[MAD]%s*$") or line:match("??%s*$") then 
        has_status_symbol = true 
      end
    end
    
    assert.is_true(has_changes_group, "Should show Changes group")
    assert.is_true(has_staged_group, "Should show Staged Changes group")
    assert.is_true(has_file_count, "Should show file counts")
    assert.is_true(has_status_symbol, "Should show status symbols")
  end)

  -- Test 6: First file is auto-selected and displayed
  it("Selects the first visible file in list view", function()
    local explorer, session = open_initial_explorer(temp_dir, "list")
    assert_first_visible_file_selected(explorer, session, "file1.txt")
  end)

  it("Selects the first visible file in tree view", function()
    local explorer, session = open_initial_explorer(temp_dir, "tree")
    assert_first_visible_file_selected(explorer, session, "nested/deep.txt")
  end)

  it("Re-renders the explorer buffer when toggle_view_mode flips the mode (regression #486)", function()
    -- PR #486 added a "skip refresh when git status unchanged" optimization at
    -- refresh.lua that made toggle_view_mode a no-op: view_mode is a client-only
    -- config, so flipping it never changes git status, and the deep_equal skip
    -- fired before the tree got rebuilt. Fix: toggle_view_mode now uses
    -- rebuild_from_cache (like toggle_group) instead of the async refresh path.
    local explorer = open_initial_explorer(temp_dir, "list")
    local before_lines = vim.api.nvim_buf_get_lines(explorer.bufnr, 0, -1, false)
    local before_mode = config.options.explorer.view_mode

    require("codediff.ui.explorer.actions").toggle_view_mode(explorer)
    vim.wait(200)

    local after_lines = vim.api.nvim_buf_get_lines(explorer.bufnr, 0, -1, false)
    local after_mode = config.options.explorer.view_mode

    assert.equals("list", before_mode)
    assert.equals("tree", after_mode)
    assert.is_false(
      vim.deep_equal(before_lines, after_lines),
      "Explorer buffer must re-render when view_mode flips (bug: skip check swallowed the rebuild)"
    )
  end)

  it("Does not select files excluded from the explorer", function()
    local explorer, session = open_initial_explorer(temp_dir, "list", { "file1.txt", "file3.txt" })
    assert_first_visible_file_selected(explorer, session, "nested/deep.txt")
  end)

  -- Test 7: Lifecycle session is created correctly
  it("Creates lifecycle session with explorer mode", function()
    vim.cmd("edit " .. temp_dir .. "/file1.txt")
    vim.cmd("CodeDiff")
    
    vim.wait(3000, function()
      return vim.fn.winnr('$') == 3
    end)
    
    local tabpage = vim.api.nvim_get_current_tabpage()
    local has_lifecycle, lifecycle = pcall(require, 'codediff.ui.lifecycle')
    if not has_lifecycle then
      pending("lifecycle module not available in test context")
      return
    end
    
    local session = lifecycle.get_session(tabpage)
    
    assert.is_not_nil(session, "Should have lifecycle session")
    assert.equal("explorer", session.panel and session.panel.name, "Session panel should be explorer")
    assert.is_not_nil(session.git_root, "Should have git_root")
  end)

  -- Test 8: No changes shows appropriate message
  it("Shows message when no changes exist", function()
    -- Commit all changes to have clean working tree
    h.git_cmd(temp_dir, "add -A")
    h.git_cmd(temp_dir, 'commit -m "Clean"')
    
    local notified = false
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if msg:match("No changes") then
        notified = true
      end
      original_notify(msg, level)
    end
    
    vim.cmd("edit " .. temp_dir .. "/file1.txt")
    vim.cmd("CodeDiff")
    
    vim.wait(2000, function() return notified end)
    
    vim.notify = original_notify
    assert.is_true(notified, "Should notify when no changes")
  end)

  -- Test 9: Non-git directory shows error
  it("Shows error for non-git directory", function()
    local non_git_dir = vim.fn.tempname()
    vim.fn.mkdir(non_git_dir, "p")
    
    -- Create a dummy file so we have something to edit
    local dummy_file = non_git_dir .. "/dummy.txt"
    vim.fn.writefile({"test"}, dummy_file)
    
    -- Change to non-git directory  
    local saved_cwd = vim.fn.getcwd()
    vim.fn.chdir(non_git_dir)
    
    local notified = false
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if msg:match("Not in a git repository") or msg:match("not a git repository") then
        notified = true
      end
      original_notify(msg, level)
    end
    
    vim.cmd("edit " .. dummy_file)
    vim.cmd("CodeDiff")
    
    vim.wait(2000, function() return notified end)
    
    vim.notify = original_notify
    
    -- Restore directory before cleanup
    vim.fn.chdir(saved_cwd)
    vim.fn.delete(non_git_dir, "rf")
    
    assert.is_true(notified, "Should notify for non-git directory")
  end)

  it("Opens the explorer file under the cursor in the previous tab", function()
    require("codediff").setup({
      diff = { layout = "side-by-side" },
      explorer = { auto_open_on_cursor = true },
      keymaps = { view = { open_in_prev_tab = "P" } },
    })

    local previous_tab = vim.api.nvim_get_current_tabpage()
    local ready, tabpage, explorer = open_explorer(temp_dir, "file1.txt")
    assert.is_true(ready, "Explorer should be ready with an initial selection")
    vim.api.nvim_set_current_tabpage(tabpage)

    local target_line, target_path = find_file_node(explorer, function(data)
      return data.path ~= explorer.current_file_path
    end)
    assert.is_not_nil(target_line, "Should find a different file node")

    vim.api.nvim_set_current_win(explorer.winid)
    vim.api.nvim_win_set_cursor(explorer.winid, { target_line, 0 })
    local callback = vim.api.nvim_buf_call(explorer.bufnr, function()
      return vim.fn.maparg("P", "n", false, true).callback
    end)
    assert.is_function(callback, "open_in_prev_tab mapping should exist in explorer buffer")
    callback()

    assert.equals(previous_tab, vim.api.nvim_get_current_tabpage())
    local expected_path = vim.uv.fs_realpath(vim.fs.joinpath(temp_dir, target_path))
    local actual_path = vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0))
    assert.equals(expected_path, actual_path)
  end)

  -- Test: auto_open_on_cursor opens the file under cursor after j/k
  it("Auto-opens diff under cursor when auto_open_on_cursor is enabled", function()
    require("codediff").setup({
      diff = { layout = "side-by-side" },
      explorer = { auto_open_on_cursor = true },
    })

    local ready, tabpage, explorer = open_explorer(temp_dir, "file1.txt")
    assert.is_true(ready, "Explorer should be ready with an initial selection")
    vim.api.nvim_set_current_tabpage(tabpage)

    local initial_path = explorer.current_file_path
    local initial_group = explorer.current_file_group

    -- Find a file node and its delta from the current cursor line.
    local cur_line = vim.api.nvim_win_get_cursor(explorer.winid)[1]
    local target_line, target_path, target_group = find_file_node(explorer, function(data)
      return data.path ~= initial_path or data.group ~= initial_group
    end)
    assert.is_not_nil(target_line, "Should find a second file node to navigate to")

    -- Press j (or k) the right number of times to reach the target line.
    -- 'tx' flag = typed + execute, which lets buffer-local mappings fire.
    vim.api.nvim_set_current_win(explorer.winid)
    local motion = target_line > cur_line and "j" or "k"
    local count = math.abs(target_line - cur_line)
    vim.api.nvim_feedkeys(string.rep(motion, count), "tx", false)

    local opened = vim.wait(2000, function()
      return explorer.current_file_path == target_path
        and explorer.current_file_group == target_group
    end, 20)
    assert.is_true(opened, "j/k on a file node should auto-open its diff")
  end)

  it("Ignores j/k landing on group/directory nodes when auto_open_on_cursor is enabled", function()
    require("codediff").setup({
      diff = { layout = "side-by-side" },
      explorer = {
        auto_open_on_cursor = true,
        view_mode = "tree", -- ensure directory nodes are present
      },
    })

    -- Add a nested file so the tree has a directory node
    vim.fn.mkdir(temp_dir .. "/nested", "p")
    vim.fn.writefile({"deep"}, temp_dir .. "/nested/deep.txt")

    local ready, tabpage, explorer = open_explorer(temp_dir, "file1.txt")
    assert.is_true(ready, "Explorer should be ready")
    vim.api.nvim_set_current_tabpage(tabpage)

    -- Find a line immediately before a group/directory node — pressing j
    -- once will land us on it.
    local skip_line, jump_from_line
    local line_count = vim.api.nvim_buf_line_count(explorer.bufnr)
    for line = 1, line_count - 1 do
      local node = explorer.tree:get_node(line + 1)
      if node and node.data and (node.data.type == "group" or node.data.type == "directory") then
        skip_line = line + 1
        jump_from_line = line
        break
      end
    end
    assert.is_not_nil(skip_line, "Should find a group/directory node line")

    vim.api.nvim_set_current_win(explorer.winid)
    vim.api.nvim_win_set_cursor(explorer.winid, { jump_from_line, 0 })

    -- Capture state *after* manual cursor placement (which itself doesn't
    -- trigger our keymap, only j/k do).
    local before_path = explorer.current_file_path
    local before_group = explorer.current_file_group

    -- One j: lands on the skip_line (which is a group/dir).
    vim.api.nvim_feedkeys("j", "tx", false)

    vim.wait(150)
    -- After landing on a group/dir, current_file_path must not have changed
    -- from before the j keypress.
    assert.equals(before_path, explorer.current_file_path,
      "Group/directory nodes should not trigger auto-open")
    assert.equals(before_group, explorer.current_file_group,
      "Group/directory nodes should not change current group")
  end)

  -- Test 10: Commands.lua simplicity (no callbacks in commands)
  it("Commands.lua follows simple pattern", function()
    -- This is a design validation test
    -- Verify commands.lua doesn't contain on_file_select
    local commands_path = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h") 
      .. "/lua/vscode-diff/commands.lua"
    
    if vim.fn.filereadable(commands_path) == 1 then
      local content = table.concat(vim.fn.readfile(commands_path), "\n")
      -- Should NOT define on_file_select in commands.lua
      local has_callback_def = content:match("local%s+function%s+on_file_select")
      assert.is_nil(has_callback_def, 
        "Commands.lua should not define on_file_select callback")
    end
  end)
end)
