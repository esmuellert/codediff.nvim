-- Test: render/lifecycle.lua - Lifecycle and cleanup management
-- Critical tests for preventing memory leaks and state corruption

local lifecycle = require("codediff.ui.lifecycle")
local highlights = require("codediff.ui.highlights")
local diff = require('codediff.core.diff')

describe("Render Lifecycle", function()
  before_each(function()
    highlights.setup()
    lifecycle.setup()
  end)

  after_each(function()
    lifecycle.cleanup_all()
  end)

  -- Test 1: Create and complete new diff session
  it("Creates and completes a new diff session successfully", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd('tabnew')
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd('vsplit')
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd('wincmd l')
    local right_win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_buf(left_win, left_buf)
    vim.api.nvim_win_set_buf(right_win, right_buf)

    local original = {"line 1", "line 2"}
    local modified = {"line 1", "line 3"}
    local lines_diff = diff.compute_diff(original, modified)

    -- Should create session without error (now single-step)
    local success = pcall(function()
      lifecycle.create_session(tabpage, {
        original = "test_file1.txt",
        modified = "test_file2.txt",
        original_revision = "WORKING",
        modified_revision = "WORKING",
      }, {
        original_bufnr = left_buf,
        modified_bufnr = right_buf,
        original_win = left_win,
        modified_win = right_win,
        lines_diff = lines_diff,
      })
    end)

    assert.is_true(success, "Should create and complete session without error")
    assert.is_nil(lifecycle.get_session(tabpage).single_side)

    vim.cmd('tabclose')
    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 2: Cleanup removes highlights
  it("Cleanup removes all highlights from buffers", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd('tabnew')
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd('vsplit')
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd('wincmd l')
    local right_win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_buf(left_win, left_buf)
    vim.api.nvim_win_set_buf(right_win, right_buf)

    local original = {"line 1"}
    local modified = {"line 1", "added"}
    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    lifecycle.create_session(tabpage, {
        original = "test_file1.txt",
        modified = "test_file2.txt",
        original_revision = "WORKING",
        modified_revision = "WORKING",
    }, {
        original_bufnr = left_buf,
        modified_bufnr = right_buf,
        original_win = left_win,
        modified_win = right_win,
        lines_diff = lines_diff,
    })

    -- Manually add some highlights to verify cleanup
    vim.api.nvim_buf_set_extmark(right_buf, highlights.ns_highlight, 1, 0, {
      end_col = 5,
      hl_group = "CodeDiffAdd"
    })

    local marks_before = vim.api.nvim_buf_get_extmarks(right_buf, highlights.ns_highlight, 0, -1, {})
    assert.is_true(#marks_before > 0, "Should have highlights before cleanup")

    lifecycle.cleanup(tabpage)

    local marks_after = vim.api.nvim_buf_get_extmarks(right_buf, highlights.ns_highlight, 0, -1, {})
    assert.equal(0, #marks_after, "All highlights should be cleared after cleanup")

    vim.cmd('tabclose')
    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 3: Cleanup removes filler extmarks
  it("Cleanup removes all filler extmarks from buffers", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd('tabnew')
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd('vsplit')
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd('wincmd l')
    local right_win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_buf(left_win, left_buf)
    vim.api.nvim_win_set_buf(right_win, right_buf)

    local original = {"line 1"}
    local modified = {"line 1", "line 2", "line 3"}
    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    lifecycle.create_session(tabpage, {
        original = "test_file1.txt",
        modified = "test_file2.txt",
        original_revision = "WORKING",
        modified_revision = "WORKING",
    }, {
        original_bufnr = left_buf,
        modified_bufnr = right_buf,
        original_win = left_win,
        modified_win = right_win,
        lines_diff = lines_diff,
    })

    -- Manually add filler
    vim.api.nvim_buf_set_extmark(left_buf, highlights.ns_filler, 0, 0, {
      virt_lines = {{{" ", "CodeDiffFiller"}}},
    })

    local fillers_before = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_filler, 0, -1, {})
    assert.is_true(#fillers_before > 0, "Should have fillers before cleanup")

    lifecycle.cleanup(tabpage)

    local fillers_after = vim.api.nvim_buf_get_extmarks(left_buf, highlights.ns_filler, 0, -1, {})
    assert.equal(0, #fillers_after, "All fillers should be cleared after cleanup")

    vim.cmd('tabclose')
    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 4: Cleanup all sessions
  it("Cleanup all removes all registered sessions", function()
    local bufs = {}
    local tabs = {}

    -- Create 3 diff sessions in different tabs
    for i = 1, 3 do
      local left_buf = vim.api.nvim_create_buf(false, true)
      local right_buf = vim.api.nvim_create_buf(false, true)
      table.insert(bufs, {left_buf, right_buf})

      vim.cmd('tabnew')
      local tabpage = vim.api.nvim_get_current_tabpage()
      table.insert(tabs, tabpage)

      vim.cmd('vsplit')
      local left_win = vim.api.nvim_get_current_win()
      vim.cmd('wincmd l')
      local right_win = vim.api.nvim_get_current_win()

      vim.api.nvim_win_set_buf(left_win, left_buf)
      vim.api.nvim_win_set_buf(right_win, right_buf)

      local original = {"line 1"}
      local modified = {"line 1", "added"}
      local lines_diff = diff.compute_diff(original, modified)

      lifecycle.create_session(tabpage, {
        original = "test_file1.txt",
        modified = "test_file2.txt",
        original_revision = "WORKING",
        modified_revision = "WORKING",
      }, {
        original_bufnr = left_buf,
        modified_bufnr = right_buf,
        original_win = left_win,
        modified_win = right_win,
        lines_diff = lines_diff,
      })
    end

    -- Should cleanup all without error AND leave no session registered.
    local success = pcall(function()
      lifecycle.cleanup_all()
    end)

    assert.is_true(success, "Should cleanup all sessions without error")
    for _, tp in ipairs(tabs) do
      assert.is_nil(lifecycle.get_session(tp),
        "cleanup_all must remove every registered session, but tab " .. tostring(tp) .. " still has one")
    end

    -- Cleanup tabs and buffers
    for _, tab in ipairs(tabs) do
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd('tabclose')
    end
    for _, buf_pair in ipairs(bufs) do
      vim.api.nvim_buf_delete(buf_pair[1], {force = true})
      vim.api.nvim_buf_delete(buf_pair[2], {force = true})
    end
  end)

  -- Test 5: Autocmds are set up
  it("Sets up autocmds for cleanup triggers", function()
    lifecycle.setup_autocmds()

    -- Verify autocmd group exists
    local augroups = vim.api.nvim_get_autocmds({group = "codediff_lifecycle"})
    assert.is_true(#augroups > 0, "Should create autocmd group with commands")
  end)

  -- Test 6: Multiple register calls for same tabpage
  it("Handles multiple register calls for the same tabpage", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd('tabnew')
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd('vsplit')
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd('wincmd l')
    local right_win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_buf(left_win, left_buf)
    vim.api.nvim_win_set_buf(right_win, right_buf)

    local original = {"line 1"}
    local modified = {"line 2"}
    local lines_diff = diff.compute_diff(original, modified)

    -- Register once
    lifecycle.create_session(tabpage, {
        original = "test_file1.txt",
        modified = "test_file2.txt",
        original_revision = "WORKING",
        modified_revision = "WORKING",
    }, {
        original_bufnr = left_buf,
        modified_bufnr = right_buf,
        original_win = left_win,
        modified_win = right_win,
        lines_diff = lines_diff,
    })

    -- Register again with updated data
    local original2 = {"line 3"}
    local modified2 = {"line 4"}
    local lines_diff2 = diff.compute_diff(original2, modified2)

    local success = pcall(function()
      lifecycle.create_session(tabpage, {
        original = "test_file3.txt",
        modified = "test_file4.txt",
        original_revision = "WORKING",
        modified_revision = "WORKING",
      }, {
        original_bufnr = left_buf,
        modified_bufnr = right_buf,
        original_win = left_win,
        modified_win = right_win,
        lines_diff = lines_diff,
      })
    end)

    assert.is_true(success, "Should handle re-registration without error")
    -- Re-registration must overwrite: the session for this tab reflects the
    -- new paths, not the initial ones. Without this check a re-register that
    -- silently no-ops would slip through.
    local sess = lifecycle.get_session(tabpage)
    assert.is_not_nil(sess, "session must still exist after re-registration")
    assert.equal("test_file3.txt", sess.original,
      "re-registration must overwrite `original` with the new value; got " .. tostring(sess.original))
    assert.equal("test_file4.txt", sess.modified,
      "re-registration must overwrite `modified` with the new value; got " .. tostring(sess.modified))

    vim.cmd('tabclose')
    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 7: Cleanup invalid tabpage
  it("Handles cleanup of non-existent tabpage gracefully", function()
    -- Register a real session first so we can assert cleanup with a bogus
    -- tabpage doesn't accidentally wipe other sessions.
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)
    vim.cmd('tabnew')
    local real_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd('vsplit')
    local lw = vim.api.nvim_get_current_win()
    vim.cmd('wincmd l')
    local rw = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(lw, left_buf)
    vim.api.nvim_win_set_buf(rw, right_buf)
    local ld = diff.compute_diff({ "a" }, { "b" })
    lifecycle.create_session(real_tab, {
        original = "a.txt",
        modified = "b.txt",
        original_revision = "WORKING",
        modified_revision = "WORKING",
    }, {
        original_bufnr = left_buf,
        modified_bufnr = right_buf,
        original_win = lw,
        modified_win = rw,
        lines_diff = ld,
    })
    assert.is_not_nil(lifecycle.get_session(real_tab))

    local fake_tabpage = 99999

    -- Should not crash AND must not clobber the real session.
    local success = pcall(function()
      lifecycle.cleanup(fake_tabpage)
    end)

    assert.is_true(success, "Should handle invalid tabpage cleanup gracefully")
    assert.is_not_nil(lifecycle.get_session(real_tab),
      "cleanup(bogus_tabpage) must not remove sessions belonging to other tabs")

    vim.cmd('tabclose')
    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)

  -- Test 8: Cleanup with invalid buffers
  it("Handles cleanup when buffers are already deleted", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd('tabnew')
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd('vsplit')
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd('wincmd l')
    local right_win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_buf(left_win, left_buf)
    vim.api.nvim_win_set_buf(right_win, right_buf)

    local original = {"line 1"}
    local modified = {"line 2"}
    local lines_diff = diff.compute_diff(original, modified)

    lifecycle.create_session(tabpage, {
        original = "test_file1.txt",
        modified = "test_file2.txt",
        original_revision = "WORKING",
        modified_revision = "WORKING",
    }, {
        original_bufnr = left_buf,
        modified_bufnr = right_buf,
        original_win = left_win,
        modified_win = right_win,
        lines_diff = lines_diff,
    })

    -- Delete buffers before cleanup
    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})

    -- Cleanup should not crash AND must remove the entry from the registry.
    local success = pcall(function()
      lifecycle.cleanup(tabpage)
    end)

    assert.is_true(success, "Should handle cleanup with deleted buffers gracefully")
    assert.is_nil(lifecycle.get_session(tabpage),
      "cleanup must remove the session even when its buffers are already gone")

    -- Close tab manually (don't use tabclose which might fail if it's the last tab)
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      pcall(vim.cmd, 'tabclose!')
    end
  end)

  -- Test 9: Session tracks buffer numbers correctly
  it("Registered session tracks correct buffer numbers", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd('tabnew')
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd('vsplit')
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd('wincmd l')
    local right_win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_buf(left_win, left_buf)
    vim.api.nvim_win_set_buf(right_win, right_buf)

    local original = {"line 1"}
    local modified = {"line 2"}
    local lines_diff = diff.compute_diff(original, modified)

    lifecycle.create_session(tabpage, {
        original = "test_file1.txt",
        modified = "test_file2.txt",
        original_revision = "WORKING",
        modified_revision = "WORKING",
    }, {
        original_bufnr = left_buf,
        modified_bufnr = right_buf,
        original_win = left_win,
        modified_win = right_win,
        lines_diff = lines_diff,
    })

    -- Verify buffers are valid and accessible
    assert.is_true(vim.api.nvim_buf_is_valid(left_buf), "Left buffer should be valid")
    assert.is_true(vim.api.nvim_buf_is_valid(right_buf), "Right buffer should be valid")

    vim.cmd('tabclose')
    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 10: Session tracks window numbers correctly
  it("Registered session tracks correct window numbers", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd('tabnew')
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd('vsplit')
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd('wincmd l')
    local right_win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_buf(left_win, left_buf)
    vim.api.nvim_win_set_buf(right_win, right_buf)

    local original = {"line 1"}
    local modified = {"line 2"}
    local lines_diff = diff.compute_diff(original, modified)

    lifecycle.create_session(tabpage, {
        original = "test_file1.txt",
        modified = "test_file2.txt",
        original_revision = "WORKING",
        modified_revision = "WORKING",
    }, {
        original_bufnr = left_buf,
        modified_bufnr = right_buf,
        original_win = left_win,
        modified_win = right_win,
        lines_diff = lines_diff,
    })

    -- Verify windows are valid
    assert.is_true(vim.api.nvim_win_is_valid(left_win), "Left window should be valid")
    assert.is_true(vim.api.nvim_win_is_valid(right_win), "Right window should be valid")

    vim.cmd('tabclose')
    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 11: Cleanup doesn't affect other sessions
  it("Cleanup of one session doesn't affect other sessions", function()
    -- Create two sessions
    local bufs1 = {vim.api.nvim_create_buf(false, true), vim.api.nvim_create_buf(false, true)}
    local bufs2 = {vim.api.nvim_create_buf(false, true), vim.api.nvim_create_buf(false, true)}

    vim.cmd('tabnew')
    local tab1 = vim.api.nvim_get_current_tabpage()
    vim.cmd('vsplit')
    local left_win1 = vim.api.nvim_get_current_win()
    vim.cmd('wincmd l')
    local right_win1 = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(left_win1, bufs1[1])
    vim.api.nvim_win_set_buf(right_win1, bufs1[2])

    vim.cmd('tabnew')
    local tab2 = vim.api.nvim_get_current_tabpage()
    vim.cmd('vsplit')
    local left_win2 = vim.api.nvim_get_current_win()
    vim.cmd('wincmd l')
    local right_win2 = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(left_win2, bufs2[1])
    vim.api.nvim_win_set_buf(right_win2, bufs2[2])

    local original = {"line 1"}
    local modified = {"line 2"}
    local lines_diff = diff.compute_diff(original, modified)

    -- Set buffer content first
    vim.api.nvim_buf_set_lines(bufs2[1], 0, -1, false, {"test line"})

    lifecycle.create_session(tab1, {
      original = "test_file1.txt",
      modified = "test_file2.txt",
      original_revision = "WORKING",
      modified_revision = "WORKING",
    }, {
      original_bufnr = bufs1[1],
      modified_bufnr = bufs1[2],
      original_win = left_win1,
      modified_win = right_win1,
      lines_diff = lines_diff,
    })
    lifecycle.create_session(tab2, {
      original = "test_file1.txt",
      modified = "test_file2.txt",
      original_revision = "WORKING",
      modified_revision = "WORKING",
    }, {
      original_bufnr = bufs2[1],
      modified_bufnr = bufs2[2],
      original_win = left_win2,
      modified_win = right_win2,
      lines_diff = lines_diff,
    })

    -- Add highlights to session 2
    vim.api.nvim_buf_set_extmark(bufs2[1], highlights.ns_highlight, 0, 0, {
      end_col = 4,
      hl_group = "CodeDiffDelete"
    })

    -- Cleanup session 1
    lifecycle.cleanup(tab1)

    -- Session 2 highlights should still exist
    local marks_session2 = vim.api.nvim_buf_get_extmarks(bufs2[1], highlights.ns_highlight, 0, -1, {})
    assert.is_true(#marks_session2 > 0, "Other session highlights should remain after cleanup")

    -- Cleanup
    vim.api.nvim_set_current_tabpage(tab1)
    vim.cmd('tabclose')
    vim.api.nvim_set_current_tabpage(tab2)
    vim.cmd('tabclose')
    for _, buf in ipairs(bufs1) do vim.api.nvim_buf_delete(buf, {force = true}) end
    for _, buf in ipairs(bufs2) do vim.api.nvim_buf_delete(buf, {force = true}) end
  end)

  -- Test 12: Register with empty lines
  it("Handles registration with empty line arrays", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd('tabnew')
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd('vsplit')
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd('wincmd l')
    local right_win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_buf(left_win, left_buf)
    vim.api.nvim_win_set_buf(right_win, right_buf)

    local original = {}
    local modified = {}
    local lines_diff = diff.compute_diff(original, modified)

    local success = pcall(function()
      lifecycle.create_session(tabpage, {
        original = "test_file1.txt",
        modified = "test_file2.txt",
        original_revision = "WORKING",
        modified_revision = "WORKING",
      }, {
        original_bufnr = left_buf,
        modified_bufnr = right_buf,
        original_win = left_win,
        modified_win = right_win,
        lines_diff = lines_diff,
      })
    end)

    assert.is_true(success, "Should handle empty lines without error")
    -- Empty-diff sessions must still be registered — the plugin never treats
    -- "no diff" as "no session" (that would defeat the welcome-page path).
    local sess = lifecycle.get_session(tabpage)
    assert.is_not_nil(sess, "session must be created even when the diff is empty")
    assert.equal(left_buf, sess.original_bufnr)
    assert.equal(right_buf, sess.modified_bufnr)

    vim.cmd('tabclose')
    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 13: Setup can be called multiple times
  it("Setup can be called multiple times without issues", function()
    lifecycle.setup()
    lifecycle.setup()
    lifecycle.setup()

    -- Should not crash or create duplicate autocmds
    local augroups = vim.api.nvim_get_autocmds({group = "codediff_lifecycle"})
    assert.is_true(#augroups > 0, "Should have autocmds after multiple setups")
  end)

  -- Test 14: Cleanup preserves buffer content
  it("Cleanup removes only extmarks, preserves buffer content", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd('tabnew')
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd('vsplit')
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd('wincmd l')
    local right_win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_buf(left_win, left_buf)
    vim.api.nvim_win_set_buf(right_win, right_buf)

    local original = {"line 1", "line 2", "line 3"}
    local modified = {"line 1", "modified", "line 3"}

    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    lifecycle.create_session(tabpage, {
        original = "test_file1.txt",
        modified = "test_file2.txt",
        original_revision = "WORKING",
        modified_revision = "WORKING",
    }, {
        original_bufnr = left_buf,
        modified_bufnr = right_buf,
        original_win = left_win,
        modified_win = right_win,
        lines_diff = lines_diff,
    })

    lifecycle.cleanup(tabpage)

    -- Content should remain
    local left_lines = vim.api.nvim_buf_get_lines(left_buf, 0, -1, false)
    local right_lines = vim.api.nvim_buf_get_lines(right_buf, 0, -1, false)

    assert.are.same(original, left_lines, "Left buffer content should be preserved")
    assert.are.same(modified, right_lines, "Right buffer content should be preserved")

    vim.cmd('tabclose')
    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)

  -- Test 15: Cleanup with closed windows
  it("Handles cleanup when windows are already closed", function()
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd('tabnew')
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd('vsplit')
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd('wincmd l')
    local right_win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_buf(left_win, left_buf)
    vim.api.nvim_win_set_buf(right_win, right_buf)

    local original = {"line 1"}
    local modified = {"line 2"}
    local lines_diff = diff.compute_diff(original, modified)

    lifecycle.create_session(tabpage, {
        original = "test_file1.txt",
        modified = "test_file2.txt",
        original_revision = "WORKING",
        modified_revision = "WORKING",
    }, {
        original_bufnr = left_buf,
        modified_bufnr = right_buf,
        original_win = left_win,
        modified_win = right_win,
        lines_diff = lines_diff,
    })

    -- Close one window
    vim.api.nvim_win_close(left_win, true)

    -- Cleanup should not crash AND must remove the entry from the registry.
    local success = pcall(function()
      lifecycle.cleanup(tabpage)
    end)

    assert.is_true(success, "Should handle cleanup with closed windows gracefully")
    assert.is_nil(lifecycle.get_session(tabpage),
      "cleanup must remove the session even when one of its windows was already closed")

    vim.cmd('tabclose')
    vim.api.nvim_buf_delete(left_buf, {force = true})
    vim.api.nvim_buf_delete(right_buf, {force = true})
  end)
end)
