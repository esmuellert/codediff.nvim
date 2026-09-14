-- Test explorer staging/unstaging workflow with virtual files
-- This tests buffer management during file switching in explorer mode

local h = require("tests.support")
local path = require("codediff.core.path")

-- Ensure plugin is loaded (needed when the test framework isolates specs)
h.ensure_plugin_loaded()

describe("Explorer Buffer Management", function()
  local repo

  before_each(function()
    -- Create a temp git repo using helper
    repo = h.create_temp_git_repo()

    -- Create initial file and commit
    repo.write_file("test.txt", { "line 1", "line 2", "line 3" })
    repo.git("add test.txt")
    repo.git("commit -m initial")
  end)

  after_each(function()
    -- Close all extra tabs before cleanup
    h.close_extra_tabs()

    -- Cleanup temp directory
    if repo then
      repo.cleanup()
    end
  end)

  it("should parse virtual file URLs correctly", function()
    local virtual_file = require("codediff.core.virtual_file")

    -- Use the actual repo.dir for cross-platform compatibility
    local normalized_dir = h.normalize_path(repo.dir)

    -- Test HEAD revision
    local url1 = virtual_file.create_url(repo.dir, "HEAD", "file.txt")
    local g1, c1, f1 = virtual_file.parse_url(url1)
    assert.equals(normalized_dir, g1)
    assert.equals("HEAD", c1)
    assert.equals("file.txt", f1)

    -- Test :0 (staged) revision
    local url2 = virtual_file.create_url(repo.dir, ":0", "file.txt")
    local g2, c2, f2 = virtual_file.parse_url(url2)
    assert.equals(normalized_dir, g2)
    assert.equals(":0", c2)
    assert.equals("file.txt", f2)

    -- Test SHA hash
    local url3 = virtual_file.create_url(repo.dir, "abc123def456", "file.txt")
    local g3, c3, f3 = virtual_file.parse_url(url3)
    assert.equals(normalized_dir, g3)
    assert.equals("abc123def456", c3)
    assert.equals("file.txt", f3)
  end)

  it("should load virtual file content via BufReadCmd", function()
    local virtual_file = require("codediff.core.virtual_file")

    -- Listen for the loaded event
    local event_fired = false
    local event_buf = nil
    vim.api.nvim_create_autocmd("User", {
      pattern = "CodeDiffVirtualFileLoaded",
      callback = function(args)
        event_fired = true
        event_buf = args.data and args.data.buf
      end,
    })

    -- Create and edit a virtual file URL
    local url = virtual_file.create_url(repo.dir, ":0", "test.txt")
    vim.cmd("edit! " .. vim.fn.fnameescape(url))
    local buf = vim.api.nvim_get_current_buf()

    -- Wait for async loading to complete
    local ok = vim.wait(5000, function()
      return event_fired
    end, 50)

    assert.is_true(ok, "Event should fire within timeout")
    assert.is_true(event_fired, "CodeDiffVirtualFileLoaded should fire")
    assert.equals(buf, event_buf, "Event should report correct buffer")

    -- Verify buffer content matches git content
    local content = h.get_buffer_content(buf)
    assert.is_not_nil(content, "Buffer should have content")
    h.assert_contains(content, "line 1", "Should contain file content")
  end)

  it("should refresh staged content when index changes", function()
    -- This tests the full staging workflow:
    -- 1. Make change A -> validate in Changes
    -- 2. Stage change A -> validate in Staged Changes
    -- 3. Make change B -> validate Changes has B, Staged has A
    -- 4. Stage change B -> validate Staged has A+B
    -- 5. Unstage file -> validate Changes has A+B

    local view = require("codediff.ui.view")
    local lifecycle = require("codediff.ui.lifecycle")

    -- Step 1: Make change A
    repo.write_file("test.txt", { "line 1", "line 2", "line 3", "change A" })

    -- Create diff view for unstaged changes (index vs working)
    local config_changes = {
      git_root = repo.dir,
      original = path.make_ref("test.txt", repo.dir),
      modified = path.make_ref(repo.path("test.txt"), repo.dir),
      original_revision = ":0",
      modified_revision = "WORKING",
    }

    local result = view.create(config_changes, "text")
    assert.is_not_nil(result, "Should create diff view")

    local tabpage = vim.api.nvim_get_current_tabpage()

    -- Wait for session to be ready
    local ready = h.wait_for_session_ready(tabpage)
    assert.is_true(ready, "Diff session should be ready")

    -- Validate: Changes should show "change A" in modified buffer
    local _, modified_buf = lifecycle.get_buffers(tabpage)
    assert.is_not_nil(modified_buf, "Modified buffer should exist")
    local content = h.get_buffer_content(modified_buf)
    assert.is_not_nil(content, "Content should not be nil")
    h.assert_contains(content, "change A", "Changes should show change A")

    -- Step 2: Stage change A
    repo.git("add test.txt")

    -- Switch to staged view (HEAD vs index)
    local config_staged = {
      git_root = repo.dir,
      original = path.make_ref("test.txt", repo.dir),
      modified = path.make_ref("test.txt", repo.dir),
      original_revision = "HEAD",
      modified_revision = ":0",
    }

    view.update(tabpage, config_staged, false)
    ready = h.wait_for_session_ready(tabpage)
    assert.is_true(ready, "Session should be ready after update")

    -- Validate: Staged should show "change A"
    _, modified_buf = lifecycle.get_buffers(tabpage)
    content = h.get_buffer_content(modified_buf)
    h.assert_contains(content, "change A", "Staged should show change A after staging")

    -- Step 3: Make change B (while A is staged)
    repo.write_file("test.txt", { "line 1", "line 2", "line 3", "change A", "change B" })

    -- Switch back to Changes view (index vs working)
    view.update(tabpage, config_changes, false)
    ready = h.wait_for_session_ready(tabpage)

    -- Validate: Changes should show "change B" (the new unstaged change).
    -- Poll the current modified buffer (view.update swaps it) until the async
    -- re-render lands, so this doesn't race on slow CI runners.
    h.wait_for_modified_content(tabpage, "change B", 5000)
    _, modified_buf = lifecycle.get_buffers(tabpage)
    content = h.get_buffer_content(modified_buf)
    assert.is_not_nil(content, "Step 3 content should not be nil")
    h.assert_contains(content, "change B", "Changes should show change B")

    -- Switch to Staged view - should still show only "change A"
    view.update(tabpage, config_staged, false)
    ready = h.wait_for_session_ready(tabpage)
    assert.is_true(ready, "Session should be ready after switching to staged view")

    _, modified_buf = lifecycle.get_buffers(tabpage)
    -- Wait for buffer content to actually contain expected text
    local content_ready = h.wait_for_buffer_content(modified_buf, "change A", 5000)
    assert.is_true(content_ready, "Staged buffer should contain 'change A'")
    content = h.get_buffer_content(modified_buf)
    h.assert_contains(content, "change A", "Staged should still show change A")

    -- Step 4: Stage change B
    repo.git("add test.txt")

    -- Refresh staged view
    view.update(tabpage, config_staged, false)
    ready = h.wait_for_session_ready(tabpage)
    assert.is_true(ready, "Session should be ready after step 4 update")

    -- Wait for the staged view to reflect the newly staged change B.
    h.wait_for_modified_content(tabpage, "change B", 5000)
    _, modified_buf = lifecycle.get_buffers(tabpage)
    content = h.get_buffer_content(modified_buf)
    h.assert_contains(content, "change A", "Staged should show change A after staging B")
    h.assert_contains(content, "change B", "Staged should show change B after staging B")

    -- Step 5: Unstage file
    repo.git("reset HEAD test.txt")

    -- Switch to Changes view - should now show both A and B
    view.update(tabpage, config_changes, false)
    ready = h.wait_for_session_ready(tabpage)

    -- Wait for the changes view to reflect both A and B after unstaging.
    h.wait_for_modified_content(tabpage, "change B", 5000)
    _, modified_buf = lifecycle.get_buffers(tabpage)
    content = h.get_buffer_content(modified_buf)
    h.assert_contains(content, "change A", "Changes should show change A after unstage")
    h.assert_contains(content, "change B", "Changes should show change B after unstage")
  end)
end)

-- Regression tests for https://github.com/esmuellert/codediff.nvim/issues/347
--
-- Reviewing files one group at a time: after a full stage/unstage of the file
-- being reviewed, the explorer's post-refresh re-selection advances to the
-- next file in the SAME group — staging jumps to the next unstaged file,
-- unstaging to the next staged file — instead of chasing the toggled file into
-- another group. ]f/[f navigate only files whose group is visible.
describe("Explorer review-flow re-selection (issue #347)", function()
  local repo
  local lifecycle = require("codediff.ui.lifecycle")
  local refresh_module = require("codediff.ui.refresh")
  local explorer_actions = require("codediff.ui.explorer.actions")

  before_each(function()
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    lifecycle.cleanup_all()

    repo = h.create_temp_git_repo()
    for _, name in ipairs({ "a.txt", "b.txt", "c.txt", "d.txt" }) do
      repo.write_file(name, { "original " .. name })
    end
    repo.git("add .")
    repo.git("commit -m initial")
    -- Modify all four files
    for _, name in ipairs({ "a.txt", "b.txt", "c.txt", "d.txt" }) do
      repo.write_file(name, { "modified " .. name })
    end
    -- Pre-stage c and d, leaving a and b unstaged
    repo.git("add c.txt d.txt")
  end)

  after_each(function()
    h.close_extra_tabs()
    lifecycle.cleanup_all()
    if repo then
      repo.cleanup()
    end
  end)

  -- Open a fresh explorer focused on `focus_rel` and return its explorer object.
  local function open_explorer(focus_rel)
    vim.cmd("edit " .. repo.path(focus_rel))
    local commands = require("codediff.commands")
    commands.vscode_diff({ fargs = {} })

    local explorer
    local ready = vim.wait(8000, function()
      for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
        local sess = lifecycle.get_session(tp)
        if sess and (sess.panel or {}).view and (sess.panel or {}).view.data.current_file_path ~= nil then
          explorer = (sess.panel or {}).view
          return true
        end
      end
      return false
    end, 50)
    return ready, explorer
  end

  -- Find the tree line for (path, group); nil if absent.
  local function line_for(explorer, file_path, group)
    local line_count = vim.api.nvim_buf_line_count(explorer.bufnr)
    for line = 1, line_count do
      local node = explorer.tree:get_node(line)
      if node and node.data and node.data.path == file_path and node.data.group == group then
        return line
      end
    end
    return nil
  end

  it("advances to the next unstaged file after staging the reviewed file", function()
    local ready, explorer = open_explorer("a.txt")
    assert.is_true(ready, "explorer should open with an initial selection")

    local settled = vim.wait(3000, function()
      return explorer.data.current_file_path == "a.txt" and explorer.data.current_file_group == "unstaged"
    end, 50)
    assert.is_true(settled, "initial selection should be a.txt/unstaged")

    -- Stage a.txt, then refresh (this is what the .git fs-watcher triggers).
    repo.git("add a.txt")
    refresh_module.request(explorer.tabpage, { full = true })

    -- Pre-fix: re-selection followed a.txt into the staged group
    -- (current_file_path=a.txt / group=staged). Post-fix: it advances to the
    -- next unstaged file, b.txt.
    local advanced = vim.wait(4000, function()
      return explorer.data.current_file_path == "b.txt" and explorer.data.current_file_group == "unstaged"
    end, 50)
    assert.is_true(
      advanced,
      "after staging a.txt the reviewer should advance to b.txt/unstaged, got " .. tostring(explorer.data.current_file_path) .. "/" .. tostring(explorer.data.current_file_group)
    )
  end)

  it("advances to the next staged file after unstaging the reviewed file", function()
    local ready, explorer = open_explorer("c.txt")
    assert.is_true(ready, "explorer should open with an initial selection")
    assert.is_true(
      vim.wait(3000, function()
        return explorer.data.current_file_path == "c.txt" and explorer.data.current_file_group == "staged"
      end, 50),
      "initial selection should be c.txt/staged"
    )

    -- Unstage c.txt, then refresh (what the .git fs-watcher triggers).
    repo.git("reset -- c.txt")
    refresh_module.request(explorer.tabpage, { full = true })

    -- Symmetric to staging: unstaging advances to the next *staged* file
    -- instead of chasing c.txt into the unstaged group.
    assert.is_true(
      vim.wait(4000, function()
        return explorer.data.current_file_path == "d.txt" and explorer.data.current_file_group == "staged"
      end, 50),
      "after unstaging c.txt the reviewer should advance to d.txt/staged, got " .. tostring(explorer.data.current_file_path) .. "/" .. tostring(explorer.data.current_file_group)
    )
  end)

  it("hiding/showing a group updates the tree synchronously and ]f skips hidden files", function()
    local ready, explorer = open_explorer("a.txt")
    assert.is_true(ready, "explorer should open")
    assert.is_true(
      vim.wait(3000, function()
        return explorer.data.current_file_path == "a.txt" and explorer.data.current_file_group == "unstaged"
      end, 50),
      "initial selection should be a.txt/unstaged"
    )

    -- Stage a.txt -> advances to b.txt/unstaged
    repo.git("add a.txt")
    refresh_module.request(explorer.tabpage, { full = true })
    assert.is_true(
      vim.wait(4000, function()
        return explorer.data.current_file_path == "b.txt" and explorer.data.current_file_group == "unstaged"
      end, 50),
      "should advance to b.txt/unstaged"
    )

    -- Hide the staged group (like `gs`). toggle_group rebuilds the tree
    -- synchronously from the cached status, so staged nodes are gone at once.
    explorer_actions.toggle_group(explorer, "staged")
    assert.is_nil(line_for(explorer, "c.txt", "staged"), "hiding a group must remove its files from the tree immediately")

    -- ]f can therefore never reach a hidden staged file.
    for _ = 1, 4 do
      explorer_actions.navigate_next(explorer)
      assert.equals(
        "unstaged",
        explorer.data.current_file_group,
        "]f must not visit hidden staged files (got " .. tostring(explorer.data.current_file_path) .. "/" .. tostring(explorer.data.current_file_group) .. ")"
      )
    end

    -- Show the staged group again: state updates synchronously the other way.
    explorer_actions.toggle_group(explorer, "staged")
    assert.is_not_nil(line_for(explorer, "c.txt", "staged"), "showing a group must restore its files to the tree immediately")
  end)

  it("keeps partially staged files in the unstaged group on refresh", function()
    -- Put a.txt in both groups: stage its current change, then add a new
    -- working-tree-only change.
    repo.git("add a.txt")
    repo.write_file("a.txt", { "modified a.txt", "unstaged follow-up" })
    local ready, explorer = open_explorer("a.txt")
    assert.is_true(ready, "explorer should open")
    assert.is_true(
      vim.wait(3000, function()
        return explorer.data.current_file_path == "a.txt" and explorer.data.current_file_group == "unstaged"
      end, 50),
      "initial selection should be a.txt/unstaged"
    )

    assert.is_not_nil(line_for(explorer, "a.txt", "unstaged"), "a.txt should appear in unstaged")
    assert.is_not_nil(line_for(explorer, "a.txt", "staged"), "a.txt should also appear in staged")

    refresh_module.request(explorer.tabpage, { full = true })
    vim.wait(1500)
    assert.equals("a.txt", explorer.data.current_file_path, "a.txt should still be the current file after a partial-stage refresh")
    assert.equals("unstaged", explorer.data.current_file_group, "a.txt should stay in the unstaged group")
  end)

  it("keeps the staged file selected when no unstaged files remain", function()
    local ready, explorer = open_explorer("a.txt")
    assert.is_true(ready, "explorer should open")
    assert.is_true(
      vim.wait(3000, function()
        return explorer.data.current_file_path == "a.txt" and explorer.data.current_file_group == "unstaged"
      end, 50),
      "initial selection should be a.txt/unstaged"
    )

    repo.git("add a.txt b.txt")
    refresh_module.request(explorer.tabpage, { full = true })

    assert.is_true(
      vim.wait(4000, function()
        return explorer.data.current_file_path == "a.txt" and explorer.data.current_file_group == "staged"
      end, 50),
      "when review is complete, the just-staged file should remain selected"
    )
  end)
end)
